#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/server";
import { StdioServerTransport } from "@modelcontextprotocol/server/stdio";
import { z } from "zod/v4";

// ---- 設定（環境変数）--------------------------------------------------------
const BASE_URL = (process.env.OPENSEARCH_URL ?? "http://localhost:9200").replace(/\/+$/, "");
const USERNAME = process.env.OPENSEARCH_USERNAME;
const PASSWORD = process.env.OPENSEARCH_PASSWORD;
const TIMEOUT_MS = Number(process.env.OPENSEARCH_TIMEOUT_MS ?? 15000);
const MAX_SIZE = 100; // 1回の検索で返す最大件数
const MAX_CONTENT_CHARS = 2000; // 各フィールドの本文を切り詰める文字数

// ---- 読み取り専用の保証 -------------------------------------------------------
// このサーバーが OpenSearch に送る HTTP メソッドは GET と、検索系の POST のみ。
// 検索系 POST は `_search` / `_count` / `_mget` / `_msearch` / `_analyze` に限定する。
const READ_ONLY_POST = /\/(_search|_count|_mget|_msearch|_analyze|_validate\/query|_explain)(\/|\?|$)/;

type Method = "GET" | "POST";

async function osRequest(method: Method, path: string, body?: unknown): Promise<unknown> {
  if (method === "POST" && !READ_ONLY_POST.test(path)) {
    throw new Error(`読み取り専用サーバーのため、この POST は許可されません: ${path}`);
  }
  const headers: Record<string, string> = { Accept: "application/json" };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  if (USERNAME && PASSWORD) {
    headers.Authorization = "Basic " + Buffer.from(`${USERNAME}:${PASSWORD}`).toString("base64");
  }

  const res = await fetch(`${BASE_URL}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  const text = await res.text();
  let json: unknown;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = text;
  }
  if (!res.ok) {
    throw new Error(`OpenSearch が HTTP ${res.status} を返しました: ${typeof json === "string" ? json : JSON.stringify(json)}`);
  }
  return json;
}

const enc = encodeURIComponent;

// ---- 結果整形 -----------------------------------------------------------------
/** 長い文字列（PDF 本文など）を切り詰めて、LLM のコンテキストを溢れさせないようにする */
function truncate(value: unknown): unknown {
  if (typeof value === "string") {
    return value.length > MAX_CONTENT_CHARS
      ? `${value.slice(0, MAX_CONTENT_CHARS)}…（${value.length} 文字中 ${MAX_CONTENT_CHARS} 文字を表示）`
      : value;
  }
  if (Array.isArray(value)) return value.map(truncate);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, truncate(v)]));
  }
  return value;
}

function ok(data: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
}

function fail(error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  return { content: [{ type: "text" as const, text: `失敗: ${message}` }], isError: true };
}

async function run(fn: () => Promise<unknown>) {
  try {
    return ok(await fn());
  } catch (error) {
    return fail(error);
  }
}

// ---- サーバー定義 -------------------------------------------------------------
const server = new McpServer({ name: "opensearch-readonly-mcp", version: "0.1.0" });

server.registerTool(
  "cluster_health",
  {
    description: "OpenSearch のクラスタ状態（status、ノード数、シャード数）とバージョンを取得する",
    inputSchema: z.object({}),
  },
  async () =>
    run(async () => {
      const [health, info] = (await Promise.all([
        osRequest("GET", "/_cluster/health"),
        osRequest("GET", "/"),
      ])) as [Record<string, unknown>, { version?: { number?: string; distribution?: string } }];
      return { version: info.version?.number, distribution: info.version?.distribution, health };
    }),
);

server.registerTool(
  "list_indices",
  {
    description: "インデックスの一覧（ドキュメント数、サイズ、状態）を取得する。システムインデックス（. で始まる）は既定で除外する",
    inputSchema: z.object({
      pattern: z.string().optional().describe("インデックス名のパターン。例: ja-*（省略時は全て）"),
      include_system: z.boolean().optional().describe("システムインデックスも含める（既定: false）"),
    }),
  },
  async ({ pattern, include_system }) =>
    run(async () => {
      const target = pattern ? `/${enc(pattern)}` : "";
      const rows = (await osRequest(
        "GET",
        `/_cat/indices${target}?format=json&h=index,health,status,docs.count,store.size&s=index`,
      )) as Array<{ index: string }>;
      return include_system ? rows : rows.filter((r) => !r.index.startsWith("."));
    }),
);

server.registerTool(
  "get_mapping",
  {
    description: "インデックスのマッピング（フィールド名と型、アナライザー）を取得する。検索クエリを作る前に使う",
    inputSchema: z.object({
      index: z.string().describe("インデックス名（例: ja-documents）"),
    }),
  },
  async ({ index }) => run(() => osRequest("GET", `/${enc(index)}/_mapping`)),
);

server.registerTool(
  "search",
  {
    description:
      "インデックスを検索する。query には OpenSearch の Query DSL（match, bool, term など）を渡す。" +
      "日本語の全文検索は match で行う。長い本文は切り詰めて返す。",
    inputSchema: z.object({
      index: z.string().describe("インデックス名またはパターン（例: ja-documents, ja-*）"),
      query: z.record(z.string(), z.unknown()).describe('Query DSL。例: {"match":{"content":"京都 紅葉"}}'),
      size: z.number().int().min(1).max(MAX_SIZE).optional().describe(`返す件数（既定: 10、最大: ${MAX_SIZE}）`),
      from: z.number().int().min(0).optional().describe("取得開始位置（ページング用）"),
      source: z.array(z.string()).optional().describe("返すフィールドを限定する。例: [\"title\",\"category\"]"),
      sort: z.array(z.unknown()).optional().describe('ソート指定。例: [{"published_at":"desc"}]'),
      highlight_fields: z.array(z.string()).optional().describe("ハイライトするフィールド。例: [\"attachment.content\"]"),
    }),
  },
  async ({ index, query, size, from, source, sort, highlight_fields }) =>
    run(async () => {
      const body: Record<string, unknown> = { query, size: size ?? 10 };
      if (from !== undefined) body.from = from;
      if (source) body._source = source;
      if (sort) body.sort = sort;
      if (highlight_fields?.length) {
        body.highlight = {
          fields: Object.fromEntries(highlight_fields.map((f) => [f, { fragment_size: 150, number_of_fragments: 2 }])),
        };
      }
      const res = (await osRequest("POST", `/${enc(index)}/_search`, body)) as {
        took: number;
        hits: { total: { value: number; relation: string }; hits: Array<Record<string, unknown>> };
      };
      return truncate({
        took_ms: res.took,
        total: res.hits.total,
        hits: res.hits.hits.map((h) => ({
          id: h._id,
          index: h._index,
          score: h._score,
          source: h._source,
          highlight: h.highlight,
        })),
      });
    }),
);

server.registerTool(
  "count",
  {
    description: "条件に一致するドキュメント数を数える（query 省略時は全件）",
    inputSchema: z.object({
      index: z.string().describe("インデックス名またはパターン"),
      query: z.record(z.string(), z.unknown()).optional().describe("Query DSL（省略時は全件）"),
    }),
  },
  async ({ index, query }) =>
    run(async () => {
      const res = (await osRequest("POST", `/${enc(index)}/_count`, query ? { query } : undefined)) as { count: number };
      return { count: res.count };
    }),
);

server.registerTool(
  "aggregate",
  {
    description: "集計を実行する（カテゴリ別件数など）。aggs には OpenSearch の集計 DSL を渡す。ヒット文書は返さない",
    inputSchema: z.object({
      index: z.string().describe("インデックス名またはパターン"),
      aggs: z.record(z.string(), z.unknown()).describe('集計 DSL。例: {"by_category":{"terms":{"field":"category"}}}'),
      query: z.record(z.string(), z.unknown()).optional().describe("集計対象を絞る Query DSL（省略時は全件）"),
    }),
  },
  async ({ index, aggs, query }) =>
    run(async () => {
      const body: Record<string, unknown> = { size: 0, aggs };
      if (query) body.query = query;
      const res = (await osRequest("POST", `/${enc(index)}/_search`, body)) as {
        hits: { total: unknown };
        aggregations: unknown;
      };
      return { total: res.hits.total, aggregations: res.aggregations };
    }),
);

server.registerTool(
  "get_document",
  {
    description: "ID を指定してドキュメントを1件取得する。長い本文は切り詰めて返す",
    inputSchema: z.object({
      index: z.string().describe("インデックス名"),
      id: z.string().describe("ドキュメント ID（PDF 取り込みではファイル名）"),
    }),
  },
  async ({ index, id }) =>
    run(async () => {
      const res = (await osRequest("GET", `/${enc(index)}/_doc/${enc(id)}`)) as Record<string, unknown>;
      return truncate({ index: res._index, id: res._id, found: res.found, source: res._source });
    }),
);

server.registerTool(
  "neural_search",
  {
    description:
      "Neural Search（ベクトル検索）を実行する。query_text を ML Commons モデルでベクトル化し、" +
      "knn_vector フィールドに対して類似度検索を行う。事前に ML Commons モデルがデプロイ済みであること。",
    inputSchema: z.object({
      index: z.string().describe("検索対象のインデックス名（例: ja-documents-knn）"),
      query_text: z.string().describe("自然言語のクエリテキスト。モデルがベクトル化する"),
      model_id: z.string().describe("デプロイ済み ML Commons モデルの ID"),
      vector_field: z.string().describe("knn_vector 型のフィールド名（例: content_embedding）"),
      k: z.number().int().min(1).max(100).optional().describe("返す近傍ドキュメント数（既定: 5）"),
      source: z.array(z.string()).optional().describe("返すフィールドを限定する。例: [\"title\",\"category\"]"),
      filter: z.record(z.string(), z.unknown()).optional().describe("ベクトル検索に重ねる絞り込みフィルタ（Query DSL）"),
    }),
  },
  async ({ index, query_text, model_id, vector_field, k, source, filter }) =>
    run(async () => {
      const neural: Record<string, unknown> = {
        query_text,
        model_id,
        k: k ?? 5,
      };
      if (filter) neural.filter = filter;
      const body: Record<string, unknown> = {
        query: { neural: { [vector_field]: neural } },
        size: k ?? 5,
      };
      if (source) body._source = source;
      const res = (await osRequest("POST", `/${enc(index)}/_search`, body)) as {
        took: number;
        hits: { total: { value: number; relation: string }; hits: Array<Record<string, unknown>> };
      };
      return truncate({
        took_ms: res.took,
        total: res.hits.total,
        hits: res.hits.hits.map((h) => ({
          id: h._id,
          index: h._index,
          score: h._score,
          source: h._source,
        })),
      });
    }),
);

server.registerTool(
  "hybrid_search",
  {
    description:
      "ハイブリッド検索（BM25 キーワード + ベクトル類似度）を実行する。" +
      "Neural Search プラグインの normalization-processor を使ってスコアを統合する。" +
      "日本語の全文検索精度とセマンティック検索を組み合わせたい場合に使う。",
    inputSchema: z.object({
      index: z.string().describe("検索対象のインデックス名（例: ja-documents-knn）"),
      keyword_query: z.string().describe("BM25 全文検索のキーワード"),
      keyword_field: z.string().describe("BM25 で検索するフィールド名（例: content）"),
      neural_query_text: z.string().describe("ベクトル検索のクエリテキスト（英語でも可）"),
      model_id: z.string().describe("デプロイ済み ML Commons モデルの ID"),
      vector_field: z.string().describe("knn_vector 型のフィールド名（例: content_embedding）"),
      k: z.number().int().min(1).max(100).optional().describe("ベクトル検索の近傍数（既定: 5）"),
      keyword_weight: z.number().min(0).max(1).optional().describe("BM25 の重み（0〜1、既定: 0.4）"),
      neural_weight: z.number().min(0).max(1).optional().describe("ベクトル検索の重み（0〜1、既定: 0.6）"),
      size: z.number().int().min(1).max(MAX_SIZE).optional().describe("返す件数（既定: 5）"),
      source: z.array(z.string()).optional().describe("返すフィールドを限定する。例: [\"title\",\"category\"]"),
    }),
  },
  async ({ index, keyword_query, keyword_field, neural_query_text, model_id, vector_field, k, keyword_weight, neural_weight, size, source }) =>
    run(async () => {
      const kw = keyword_weight ?? 0.4;
      const nw = neural_weight ?? 0.6;
      const body: Record<string, unknown> = {
        size: size ?? 5,
        query: {
          hybrid: {
            queries: [
              { match: { [keyword_field]: { query: keyword_query } } },
              { neural: { [vector_field]: { query_text: neural_query_text, model_id, k: k ?? 5 } } },
            ],
          },
        },
        search_pipeline: {
          phase_results_processors: [
            {
              "normalization-processor": {
                normalization: { technique: "min_max" },
                combination: {
                  technique: "arithmetic_mean",
                  parameters: { weights: [kw, nw] },
                },
              },
            },
          ],
        },
      };
      if (source) body._source = source;
      const res = (await osRequest("POST", `/${enc(index)}/_search`, body)) as {
        took: number;
        hits: { total: { value: number; relation: string }; hits: Array<Record<string, unknown>> };
      };
      return truncate({
        took_ms: res.took,
        total: res.hits.total,
        hits: res.hits.hits.map((h) => ({
          id: h._id,
          index: h._index,
          score: h._score,
          source: h._source,
        })),
      });
    }),
);

server.registerTool(
  "analyze_text",
  {
    description: "テキストを指定アナライザーで単語分割した結果を返す。日本語検索でヒットしない原因の調査に使う",
    inputSchema: z.object({
      index: z.string().describe("アナライザーを持つインデックス名（例: ja-documents）"),
      analyzer: z.string().describe("アナライザー名（例: ja_analyzer）"),
      text: z.string().describe("分析するテキスト"),
    }),
  },
  async ({ index, analyzer, text }) =>
    run(async () => {
      const res = (await osRequest("POST", `/${enc(index)}/_analyze`, { analyzer, text })) as {
        tokens: Array<{ token: string }>;
      };
      return { tokens: res.tokens.map((t) => t.token) };
    }),
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // stdout は MCP のプロトコル用。ログは必ず stderr に出す
  console.error(`opensearch-readonly-mcp running on stdio (target: ${BASE_URL})`);
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
