# AGENTS.md

This file provides guidance to agents when working with code in this repository.

ローカル検証用の OpenSearch 3.10.0 + Dashboards 環境（Podman）。テスト・lint は無い。

## コマンド
- `podman` は PATH に無い: `export PATH=$PATH:/opt/podman/bin:/usr/local/bin`（`podman compose` は `/usr/local/bin/docker-compose` を呼ぶ）
- 起動/再ビルド: `podman compose -f docker-compose.yml up --detach --build`（プラグイン追加時は `--build` 必須）。起動に数十秒かかる
- BM25 登録: `./ingest/ingest_documents.sh [dir]`（既定 `ingest/documents/`）
- ベクトル検索登録: `./ingest/setup_vector_search.sh` → `./ingest/ingest_documents_knn.sh [dir] [MODEL_ID]`（`OPENSEARCH_MODEL_ID` 環境変数でも可）
- サンプル PDF/pptx 生成: `.venv-pdf/bin/python ingest/make_samples.py`（reportlab・python-pptx は `.venv-pdf` のみ）
- MCP ビルド: `cd opensearch-mcp && npm run build`（`build/` は git 管理外。`.bob/mcp.json` は `build/index.js` を起動する）
- webapp: `cd webapp && npm start`（`localhost:3000`）。`npm run dev` は `--watch`

## 環境の制約
- `~/.docker/config.json` は `{}`（`credsStore: osxkeychain` のヘルパー未インストールで pull が失敗するため）
- `bootstrap.memory_lock=false` 固定。`true` だと Podman VM で Exit 78
- Podman VM は 4GB（`podman machine set --memory 4096`）。ヒープは `-Xms1g -Xmx1g`。作り直すときも同じにする
- `gvproxy` の `address already in use` / `connection refused` で起動失敗したら `$TMPDIR/podman/*.sock` を削除して再起動
- プラグインは `Dockerfile.opensearch` の `opensearch-plugin install --batch` に追記する（`podman exec` で入れると再作成で消える）
- `docker-compose.yml` に `version:` を書かない（obsolete 警告）
- 単一ノードなので `yellow` は正常
- `.gitignore` が `*.html` と `.bob/` を除外している。ルートの `*.html` はスクリプト出力

## MCP サーバー（`opensearch-mcp/`）
- 読み取り専用は [`src/index.ts`](opensearch-mcp/src/index.ts) の `READ_ONLY_POST` 正規表現が保証（`_search`/`_count`/`_mget`/`_msearch`/`_analyze`/`_validate/query`/`_explain` のみ許可）。書き込み系ツールを足すなら意図的に変える
- ログは `console.error` のみ（`console.log` は stdout の MCP プロトコルを壊す）
- ESM + `"moduleResolution": "Node16"` のため import に `.js` 拡張子が必要。`zod` は `from "zod/v4"`（`from "zod"` は不可）
- レスポンスは必ず `run()` 経由で `ok()`/`fail()` を返す（`isError` を正しく設定するため）。本文は `truncate()` が 2000 文字で切る
- `webapp/server.js` は CommonJS。`opensearch-mcp` は ESM。混在させない
- `hybrid_search` は `search_pipeline` をリクエストボディにインラインで渡す（事前登録方式ではない）。重み既定は BM25 0.4 / neural 0.6
- `nested_path` を省略すると `neural` を `nested` で包まず、`ja-documents-knn` では 0 件になる

## ingest の落とし穴
- `curl -f` はエラー本文を隠す。exit 22 で落ちたら `-f` を外して curl を手で叩く
- OpenSearch の `attachment` は `remove_binary` 非対応（400）。`remove` プロセッサで `data` を消す
- フォント未埋め込みの PDF は Tika が `font is null` NPE。`make_samples.py` が TTF を埋め込むのはこのため（CID フォント `HeiseiKakuGo-W5` は不可）
- `text_chunking`/`text_embedding` はドット記法（`attachment.content`）を参照できない。`script` で `_content_tmp` にコピーしてから渡す
- `ja_analyzer`（kuromoji）の定義は `ingest_documents.sh` と `ingest_documents_knn.sh` に重複。変更時は両方直す
- 両 ingest スクリプトは実行のたびにインデックスを DELETE して再作成する
- `filename` / `attachment.content_type` / `attachment.language` は `keyword` 型。`match` ではなく `term`

## ベクトル検索（ML Commons）
- モデル: `ibm-granite/granite-embedding-107m-multilingual`（384 次元・最大 512 トークン）。IBM 公式の `model.onnx`（fp32 約 428MB）を Hugging Face から取得し、zip 化してホスト上の一時 HTTP サーバー（`host.containers.internal:8765`）経由で登録する。キャッシュ `ingest/.model-cache/`（約 650MB 以上、git 管理外。旧モデルの残骸は手で消す）
- 登録は `pooling_mode: CLS` / `normalize_result: true`。ONNX の 1 つ目の出力 `logits`（トークンごと）の CLS を使う。2 つ目の出力 `894` は不一致なので使わない。`space_type: cosinesimil` はインデックスと揃える
- Granite は用途別プレフィックス不要（`検索文書: ` / `検索クエリ: ` は ruri-v3 用。付けない）
- モデルを変えると次元が変わる。`ingest_documents_knn.sh` の `dimension`（384）と、プレフィックスの要否を必ず見直す
- `ja-documents-knn`: `chunks_embedding`（`nested`）配下の `knn`（`knn_vector`、HNSW/Lucene）。`fixed_char_length` 500 文字・重複 0.1 でチャンク分割（`fixed_token_length` は日本語に不向き、`kuromoji` は選べない）。検索は `nested`（`score_mode: max`）で包む
- 外側の `bool.filter` では `k` が小さいと 0 件になる。絞り込みは `neural` の中の `filter` に書く
- メモリ閾値 99% を設定しないとデプロイできない（`setup_vector_search.sh` のクラスタ設定）
- `setup_vector_search.sh` の `wait_task` は進捗を stderr、`model_id` のみ stdout に出す。混在させると `MODEL_ID=$(...)` が壊れる
- MODEL_ID 自動検出は `_source.model_id` を優先（`_id` はチャンク ID `abc_2` になることがある）。`DEPLOYED` を先頭 1 件拾うだけなので、別次元のモデルが残っていると登録に失敗する。旧モデルは `_undeploy` → `DELETE` する
- `.plugins-ml-model` にモデルのウェイトが入る（Granite で約 390MB）。削除後も残るので、不要なら `DELETE /.plugins-ml-model,.plugins-ml-task,.plugins-ml-model-group,.plugins-ml-config`
