# opensearch-project

Podman 上の OpenSearch をローカルに構築し、日本語 PDF・Office 文書を全文検索・ベクトル検索するための環境です。

## 構成

| コンポーネント | 説明 |
|---|---|
| OpenSearch (`localhost:9200`) | 検索エンジン本体。analysis-kuromoji / ingest-attachment プラグイン込み |
| OpenSearch Dashboards (`localhost:5601`) | 管理・可視化 UI |
| `ingest/` | PDF・Office 文書をインデックスへ登録するシェルスクリプト群 |
| `webapp/` | ブラウザから全文検索できる Node.js/Express 製 Web アプリ（`localhost:3000`） |
| `opensearch-mcp/` | AI エージェント（Bob 等）から OpenSearch を検索できる読み取り専用 MCP サーバー |

## クイックスタート

```bash
# 1. PATH を追加（毎回、または ~/.zshrc に追記）
export PATH=$PATH:/opt/podman/bin:/usr/local/bin

# 2. OpenSearch + Dashboards を起動
podman compose -f docker-compose.yml up --detach --build

# 3. 起動確認（数十秒かかる）
curl localhost:9200

# 4. 文書をインデックスへ登録（ingest/documents/ に PDF/Office ファイルを置いてから実行）
./ingest/ingest_documents.sh

# 5. 検索 Web アプリを起動
cd webapp && npm install && npm start
# → http://localhost:3000
```

## インデックス

| インデックス | 用途 |
|---|---|
| `ja-documents` | BM25 全文検索用（kuromoji 形態素解析） |
| `ja-documents-knn` | ベクトル検索対応版（BM25 + kNN ハイブリッド検索可） |

## ドキュメント

| ファイル | 内容 |
|---|---|
| [SETUP.md](SETUP.md) | 環境構築の詳細手順（Podman VM・プラグイン・動作確認） |
| [ingest/README.md](ingest/README.md) | 文書登録スクリプトの仕様・落とし穴・ベクトル検索設定 |
| [webapp/README.md](webapp/README.md) | 検索 Web アプリの API リファレンス・環境変数 |
| [opensearch-mcp/README.md](opensearch-mcp/README.md) | MCP サーバーのツール一覧・設定方法 |
