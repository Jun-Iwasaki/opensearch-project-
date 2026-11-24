'use strict';

const express = require('express');
const { Client } = require('@opensearch-project/opensearch');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;
const OPENSEARCH_URL = process.env.OPENSEARCH_URL || 'http://localhost:9200';

// OpenSearch クライアント初期化
const osClient = new Client({
  node: OPENSEARCH_URL,
  ...(process.env.OPENSEARCH_USERNAME && {
    auth: {
      username: process.env.OPENSEARCH_USERNAME,
      password: process.env.OPENSEARCH_PASSWORD || '',
    },
  }),
});

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ----------------------------------------------------------------
// GET /api/indices  — 検索対象インデックス一覧
// ----------------------------------------------------------------
app.get('/api/indices', async (_req, res) => {
  try {
    const { body } = await osClient.cat.indices({
      format: 'json',
      h: 'index,docs.count,health,status',
    });
    // システムインデックス（. 始まり）と OP 系インデックスを除外
    const visible = body.filter(
      (idx) =>
        !idx.index.startsWith('.') &&
        !idx.index.startsWith('top_queries') &&
        idx.status === 'open'
    );
    res.json({ indices: visible });
  } catch (err) {
    console.error('indices error:', err.message);
    res.status(500).json({ error: 'インデックス一覧の取得に失敗しました', detail: err.message });
  }
});

// ----------------------------------------------------------------
// GET /api/fields?index=<name>  — そのインデックスの検索可能フィールド一覧
// ----------------------------------------------------------------
app.get('/api/fields', async (req, res) => {
  const { index } = req.query;
  if (!index) return res.status(400).json({ error: 'index パラメータが必要です' });

  try {
    const { body } = await osClient.indices.getMapping({ index });
    const props = body[index]?.mappings?.properties ?? {};

    // text / keyword フィールドのみ返す（ネスト1階層まで展開）
    const fields = [];
    const flatten = (obj, prefix = '') => {
      for (const [key, val] of Object.entries(obj)) {
        const fullKey = prefix ? `${prefix}.${key}` : key;
        if (val.type === 'text' || val.type === 'keyword') {
          fields.push({ field: fullKey, type: val.type });
        } else if (val.properties) {
          flatten(val.properties, fullKey);
        }
      }
    };
    flatten(props);
    res.json({ fields });
  } catch (err) {
    console.error('fields error:', err.message);
    res.status(500).json({ error: 'フィールド取得に失敗しました', detail: err.message });
  }
});

// ----------------------------------------------------------------
// POST /api/search  — 検索実行
// body: { index, query, fields, page, pageSize, filters }
// ----------------------------------------------------------------
app.post('/api/search', async (req, res) => {
  const {
    index,
    query = '',
    fields,          // string[] | undefined
    page = 1,
    pageSize = 10,
    filters = {},    // { field: value }
  } = req.body;

  if (!index) return res.status(400).json({ error: 'index が指定されていません' });

  const from = (Math.max(1, page) - 1) * pageSize;

  try {
    // --- クエリ組み立て ---
    const mustClauses = [];

    if (query.trim()) {
      // 検索フィールドの決定（指定なければ全 text フィールドを対象）
      const searchFields = Array.isArray(fields) && fields.length > 0 ? fields : undefined;
      mustClauses.push(
        searchFields
          ? { multi_match: { query: query.trim(), fields: searchFields, type: 'best_fields', operator: 'or' } }
          : { query_string: { query: query.trim(), default_operator: 'OR' } }
      );
    }

    // フィルター（keyword フィールド等）
    const filterClauses = Object.entries(filters)
      .filter(([, v]) => v !== '' && v != null)
      .map(([field, value]) => ({ term: { [field]: value } }));

    const boolQuery =
      mustClauses.length === 0 && filterClauses.length === 0
        ? { match_all: {} }
        : {
            bool: {
              ...(mustClauses.length > 0 && { must: mustClauses }),
              ...(filterClauses.length > 0 && { filter: filterClauses }),
            },
          };

    // ハイライト対象は text フィールドのみ
    const { body: mappingBody } = await osClient.indices.getMapping({ index });
    const props = mappingBody[index]?.mappings?.properties ?? {};
    const textFields = collectTextFields(props);

    const highlightFields = {};
    textFields.forEach((f) => {
      highlightFields[f] = { number_of_fragments: 1, fragment_size: 150 };
    });

    const { body } = await osClient.search({
      index,
      body: {
        from,
        size: pageSize,
        query: boolQuery,
        highlight: {
          pre_tags: ['<mark>'],
          post_tags: ['</mark>'],
          fields: highlightFields,
        },
        // 添付ファイルの生バイナリは返さない
        _source: { excludes: ['data'] },
      },
    });

    const total = body.hits.total?.value ?? 0;
    const hits = body.hits.hits.map((h) => ({
      id: h._id,
      score: h._score,
      source: h._source,
      highlight: h.highlight ?? {},
    }));

    res.json({
      total,
      page,
      pageSize,
      totalPages: Math.ceil(total / pageSize),
      hits,
      took_ms: body.took,
    });
  } catch (err) {
    console.error('search error:', err.message);
    const status = err.meta?.statusCode ?? 500;
    res.status(status >= 400 ? status : 500).json({
      error: '検索に失敗しました',
      detail: err.message,
    });
  }
});

// ----------------------------------------------------------------
// ヘルパー: props から text フィールドを再帰的に収集
// ----------------------------------------------------------------
function collectTextFields(props, prefix = '') {
  const result = [];
  for (const [key, val] of Object.entries(props)) {
    const full = prefix ? `${prefix}.${key}` : key;
    if (val.type === 'text') result.push(full);
    if (val.properties) result.push(...collectTextFields(val.properties, full));
  }
  return result;
}

// ----------------------------------------------------------------
// GET /api/health  — クラスタ疎通確認
// ----------------------------------------------------------------
app.get('/api/health', async (_req, res) => {
  try {
    const { body } = await osClient.cluster.health();
    res.json({ status: body.status, version: body.version, nodes: body.number_of_nodes });
  } catch (err) {
    res.status(503).json({ error: 'OpenSearch に接続できません', detail: err.message });
  }
});

// ----------------------------------------------------------------
// GET /api/content-types?index=<name>  — attachment.content_type の値一覧
// ----------------------------------------------------------------
app.get('/api/content-types', async (req, res) => {
  const { index } = req.query;
  if (!index) return res.status(400).json({ error: 'index パラメータが必要です' });

  try {
    const { body } = await osClient.search({
      index,
      body: {
        size: 0,
        aggs: {
          content_types: {
            terms: { field: 'attachment.content_type', size: 50 },
          },
        },
      },
    });
    const buckets = body.aggregations?.content_types?.buckets ?? [];
    res.json({ content_types: buckets.map((b) => ({ value: b.key, count: b.doc_count })) });
  } catch (err) {
    // attachment.content_type が存在しないインデックスでは空配列を返す
    res.json({ content_types: [] });
  }
});

// SPA フォールバック
app.get('*', (_req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`✅  OpenSearch Web アプリ起動中: http://localhost:${PORT}`);
  console.log(`    OpenSearch URL: ${OPENSEARCH_URL}`);
});
