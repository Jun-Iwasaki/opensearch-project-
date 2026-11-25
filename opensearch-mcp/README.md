# opensearch-readonly-mcp

OpenSearch の**読み取り専用** MCP（Model Context Protocol）サーバーです。  
stdio トランスポートで動作し、AI エージェント（Bob / Claude 等）から OpenSearch インデックスを安全に検索・参照できます。

---

## 機能概要

- OpenSearch への **GET** および**検索系 POST** のみ許可（書き込み操作は拒否）
- クラスタ状態・インデックス一覧・マッピング取得・全文検索・集計・ベクトル検索など 10 ツールを提供
- 長い本文（PDF 全文など）を `MAX_CONTENT_CHARS=2000` 文字で自動切り詰め

---

## ディレクトリ構成

```
opensearch-mcp/
├── src/
│   └── index.ts       # メインソース（MCP サーバー定義・ツール実装）
├── build/
│   └── index.js       # コンパイル済みファイル（git 管理外）
├── package.json
├── tsconfig.json
└── README.md
```

---

## セットアップ

### 前提条件

- Node.js 18 以上
- 接続先 OpenSearch クラスタが稼働していること

### インストール・ビルド

```bash
cd opensearch-mcp
npm install
npm run build
```

> `npm run build` は `tsc && chmod 755 build/index.js` を実行します。  
> ソースを変更したら必ず再ビルドしてください（`build/` は git 管理外）。

---

## 環境変数

| 変数名 | 既定値 | 説明 |
|---|---|---|
| `OPENSEARCH_URL` | `http://localhost:9200` | 接続先 OpenSearch の URL |
| `OPENSEARCH_USERNAME` | （未設定） | Basic 認証のユーザー名 |
| `OPENSEARCH_PASSWORD` | （未設定） | Basic 認証のパスワード |
| `OPENSEARCH_TIMEOUT_MS` | `15000` | リクエストタイムアウト（ミリ秒） |

---

## Bob / Claude への登録（`.bob/mcp.json`）

```json
{
  "mcpServers": {
    "opensearch-readonly": {
      "command": "node",
      "args": ["${workspaceFolder}/opensearch-mcp/build/index.js"],
      "env": {
        "OPENSEARCH_URL": "http://localhost:9200"
      }
    }
  }
}
```

認証が必要なクラスタの場合は `env` に `OPENSEARCH_USERNAME` / `OPENSEARCH_PASSWORD` を追加してください。

---

## 提供ツール一覧

### `cluster_health`
OpenSearch のクラスタ状態（`status`・ノード数・シャード数）とバージョンを取得する。

**パラメータ:** なし

---

### `list_indices`
インデックスの一覧（ドキュメント数・サイズ・状態）を取得する。  
システムインデックス（`.` で始まる）は既定で除外。

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `pattern` | string | - | インデックス名パターン（例: `ja-*`）|
| `include_system` | boolean | - | システムインデックスを含める（既定: `false`）|

---

### `get_mapping`
インデックスのマッピング（フィールド名・型・アナライザー）を取得する。  
検索クエリを作る前に実行するとフィールド構造を把握できる。

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `index` | string | ✓ | インデックス名（例: `ja-documents`）|

---

### `search`
OpenSearch の Query DSL でインデックスを検索する。  
日本語全文検索は `match`、完全一致は `term` を使う。  
長い本文は 2000 文字で切り詰めて返す。

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `index` | string | ✓ | インデックス名またはパターン |
| `query` | object | ✓ | Query DSL |
| `size` | integer | - | 返す件数（既定: 10、最大: 100）|
| `from` | integer | - | 取得開始位置（ページング用）|
| `source` | string[] | - | 返すフィールドを限定 |
| `sort` | array | - | ソート指定 |
| `highlight_fields` | string[] | - | ハイライトするフィールド |

---

### `count`
条件に一致するドキュメント数を返す。`query` を省略すると全件数。

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `index` | string | ✓ | インデックス名またはパターン |
| `query` | object | - | Query DSL |

---

### `aggregate`
集計を実行する（カテゴリ別件数など）。  
OpenSearch の集計 DSL（`aggs`）を直接渡す。ヒット文書は返さない。

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `index` | string | ✓ | インデックス名またはパターン |
| `aggs` | object | ✓ | 集計 DSL |
| `query` | object | - | 集計対象を絞る Query DSL |

---

### `get_document`
ID を指定して 1 件取得する。長い本文は切り詰めて返す。

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `index` | string | ✓ | インデックス名 |
| `id` | string | ✓ | ドキュメント ID（PDF 取り込みではファイル名）|

---

### `neural_search`
Neural Search（ベクトル検索）を実行する。  
`query_text` を ML Commons モデルでベクトル化し、`knn_vector` フィールドと類似度検索する。  
事前に ML Commons モデルがデプロイ済みであること。

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `index` | string | ✓ | 検索対象インデックス名（例: `ja-documents-knn`）|
| `query_text` | string | ✓ | 自然言語クエリテキスト |
| `model_id` | string | ✓ | デプロイ済み ML Commons モデルの ID |
| `vector_field` | string | ✓ | `knn_vector` 型のフィールド名（例: `content_embedding`）|
| `k` | integer | - | 返す近傍ドキュメント数（既定: 5）|
| `source` | string[] | - | 返すフィールドを限定 |
| `filter` | object | - | 絞り込みフィルタ（Query DSL）|

---

### `hybrid_search`
ハイブリッド検索（BM25 キーワード + ベクトル類似度）を実行する。  
Neural Search プラグインの `normalization-processor` でスコアを統合する。  
日本語の全文検索精度とセマンティック検索を組み合わせたい場合に使う。

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `index` | string | ✓ | 検索対象インデックス名 |
| `keyword_query` | string | ✓ | BM25 全文検索のキーワード |
| `keyword_field` | string | ✓ | BM25 で検索するフィールド名 |
| `neural_query_text` | string | ✓ | ベクトル検索のクエリテキスト |
| `model_id` | string | ✓ | デプロイ済み ML Commons モデルの ID |
| `vector_field` | string | ✓ | `knn_vector` 型のフィールド名 |
| `k` | integer | - | ベクトル検索の近傍数（既定: 5）|
| `keyword_weight` | number | - | BM25 の重み（0〜1、既定: 0.4）|
| `neural_weight` | number | - | ベクトル検索の重み（0〜1、既定: 0.6）|
| `size` | integer | - | 返す件数（既定: 5）|
| `source` | string[] | - | 返すフィールドを限定 |

---

### `analyze_text`
テキストを指定アナライザーで単語分割した結果を返す。  
日本語検索でヒットしない原因の調査に使う。

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `index` | string | ✓ | アナライザーを持つインデックス名（例: `ja-documents`）|
| `analyzer` | string | ✓ | アナライザー名（例: `ja_analyzer`）|
| `text` | string | ✓ | 分析するテキスト |

---

## 実装上の注意事項

### 読み取り専用の保証

以下の正規表現でPOST先パスを制限しています。これを変更すると書き込み操作が可能になります。

```
/_search | _count | _mget | _msearch | _analyze | _validate/query | _explain
```

### ログ出力

- **`console.error`** のみ使用（stdout は MCP プロトコル用のため `console.log` は使用禁止）

### TypeScript の import パス

`"module": "Node16"` を使用しているため、import パスには `.js` 拡張子が必要です。

### 本文の切り詰め

PDF や Office ドキュメントの全文などを切り詰める `truncate()` 関数は、`MAX_CONTENT_CHARS=2000` を上限に動作します。上限を変更する場合は `src/index.ts` の定数を修正して再ビルドしてください。

---

## 関連情報

### Qiita 記事

| 記事 | 内容 |
|---|---|
| [PodmanでOpenSearchを構築してkuromojiで日本語全文検索を試す](https://qiita.com/Jungobu/items/56b579941d7e78b54c20) | 本 MCP サーバーが接続する OpenSearch 環境の構築手順（前編）|
| Podman上のOpenSearchにPDF・Office文書を取り込み、日本語全文検索する（続編） | `ingest-attachment` / `analysis-kuromoji` を使ったインデックス登録手順 |

### GitHub リポジトリ

| ファイル | 説明 |
|---|---|
| [ingest/ingest_documents.sh](https://github.com/Jun-Iwasaki/opensearch-project-/blob/main/ingest/ingest_documents.sh) | PDF・Office 文書を `ja-documents` インデックスへ登録するスクリプト |

### 関連ツール・プロダクト

| ツール | 説明 |
|---|---|
| [IBM Bob](https://www.ibm.com/products/bob) | 本プロジェクトのスクリプト開発・デバッグに利用した IBM 社内 AI コーディングアシスタント |
| [Apache Tika](https://tika.apache.org/) | `ingest-attachment` プラグインが内部で利用するドキュメント本文抽出ライブラリ |
| [OpenSearch analysis-kuromoji](https://opensearch.org/docs/latest/analyzers/language-analyzers/) | 日本語形態素解析プラグイン（`ja_analyzer` の実体）|
