# AGENTS.md

This file provides guidance to agents when working with code in this repository.

ローカル検証用の OpenSearch + Dashboards 環境（Podman）。アプリコード・テスト・lint は無い。

## コマンド
- `podman` は PATH に無い: `export PATH=$PATH:/opt/podman/bin:/usr/local/bin`（`podman compose` は `/usr/local/bin/docker-compose` を呼ぶ）
- 起動/再ビルド: `podman compose -f docker-compose.yml up --detach --build`（プラグイン追加時は `--build` 必須）
- 疎通確認: `curl localhost:9200`（起動に数十秒かかる）。Dashboards は `localhost:5601`
- PDF/Office 登録: `./sample-data/ingest_documents.sh [dir]`（既定 `sample-data/documents/`。毎回インデックスを DELETE して再作成）
- ベクトル検索対応登録: `./sample-data/setup_vector_search.sh` → `./sample-data/ingest_documents_knn.sh [dir] [MODEL_ID]`
- サンプル PDF/pptx 生成: `.venv-pdf/bin/python sample-data/make_samples.py`（reportlab と python-pptx は `.venv-pdf` のみ。git 管理外）
- MCP ビルド: `cd opensearch-mcp && npm run build`（`tsc && chmod 755 build/index.js`。`build/` は git 管理外）
- webapp 起動: `cd webapp && npm start`（`localhost:3000`。開発: `npm run dev` で `--watch` 自動再起動）

## MCP サーバー（`opensearch-mcp/`）
- TypeScript / stdio の読み取り専用 MCP。`.bob/mcp.json` の `opensearch-readonly` として登録済み
- 読み取り専用は [`src/index.ts`](opensearch-mcp/src/index.ts) の `READ_ONLY_POST` 正規表現で保証（`_search`/`_count`/`_mget`/`_msearch`/`_analyze`/`_validate/query`/`_explain` のみ許可）
- ログは `console.error` のみ。`console.log` は stdout の MCP プロトコルを壊す
- TypeScript 7 のため `tsconfig.json` に `"types": ["node"]` が必須（無いと `process` が解決できない）
- `"module": "Node16"` / `"moduleResolution": "Node16"` のため import パスに `.js` 拡張子が必要
- 接続先: `OPENSEARCH_URL`（既定 `http://localhost:9200`）。認証: `OPENSEARCH_USERNAME` / `OPENSEARCH_PASSWORD`
- 本文は `MAX_CONTENT_CHARS=2000` 文字で自動切り詰め（`truncate()` 関数）

## 非自明な制約
- `~/.docker/config.json` は `{}` にしてある（`credsStore: osxkeychain` のヘルパー未インストールで pull が失敗するため）。元は `config.json.bak`
- `bootstrap.memory_lock=false` 固定。`true` だと Podman VM で bootstrap check 失敗（Exit 78）し起動しない
- Podman VM メモリは 4GB に増設済み（`podman machine set --memory 4096`）。以前の 2GB では Exit 137（OOM）。VM を作り直す場合は同じ設定にする
- プラグインは `Dockerfile.opensearch` の `opensearch-plugin install --batch` に追記する（`podman exec` で入れると再作成で消える）。compose の image 名は `opensearch-kuromoji:latest`
- `docker-compose.yml` に `version:` を書かない（obsolete 警告が出る）
- セキュリティプラグインは無効（`DISABLE_SECURITY_PLUGIN=true`）。HTTP・認証なし。ローカル専用

## ingest-attachment の落とし穴
- OpenSearch 版は `remove_binary` 非対応（指定すると 400）。`remove` プロセッサで `data` フィールドを削除する
- フォント未埋め込みの PDF は Tika が `font is null` NPE で失敗する。`make_samples.py` が TTF を埋め込むのはこのため（CID フォント `HeiseiKakuGo-W5` は不可）
- `text_embedding` プロセッサはドット記法のネストフィールド（`attachment.content`）を直接参照できない。`script` プロセッサで `_content_tmp` に一旦コピーしてからベクトル化する（`ingest_documents_knn.sh` 参照）
- 日本語アナライザー `ja_analyzer`（kuromoji）の定義は `ingest_documents.sh` と `ingest_documents_knn.sh` に重複。変更時は両方直す

## インデックス・フィールド構造
- `ja-documents`: BM25 全文検索用。本文フィールドは `attachment.content`（`text` / `ja_analyzer`）
- `ja-documents-knn`: ベクトル検索対応版。`content_embedding`（`knn_vector`、次元 384、HNSW/Lucene）
- `filename` / `attachment.content_type` / `attachment.language` は `keyword` 型なので `match` は効かず `term` を使う
- 単一ノード構成のため `yellow` ステータスは正常（レプリカを置けるノードがない）
- `curl -f` はエラー本文を隠す。スクリプトが exit 22 で落ちたら `-f` を外して curl を手で叩く

## ベクトル検索（ML Commons）
- モデル: `paraphrase-multilingual-MiniLM-L12-v2`（`setup_vector_search.sh` でデプロイ）
- メモリ閾値を 99% に設定しないと 4GB VM でモデルがデプロイできない（`setup_vector_search.sh` の ML Commons クラスタ設定参照）
- `MODEL_ID` は `setup_vector_search.sh` 完了時に表示される。`ingest_documents_knn.sh` の引数か `OPENSEARCH_MODEL_ID` 環境変数で渡す
