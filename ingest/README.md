# ingest — 文書登録スクリプト

ローカル OpenSearch への日本語サンプルデータ登録に使うスクリプト群です。

## ファイル一覧

| ファイル | 役割 |
|---|---|
| `ingest_documents.sh` | PDF/Office 文書を `ja-documents` インデックスへ登録（BM25 検索用） |
| `ingest_documents_knn.sh` | 同文書を `ja-documents-knn` インデックスへ登録（ベクトル検索対応） |
| `make_samples.py` | テスト用日本語 PDF/PPTX を `documents/` に生成する |
| `setup_vector_search.sh` | ML Commons モデルをデプロイする（`ingest_documents_knn.sh` の前提） |

---

## クイックスタート — BM25 検索インデックスの作成手順

`ingest_documents.sh` を使って `ja-documents` インデックスを作成するまでの手順を示します。

### 前提条件

| 条件 | 確認方法 |
|---|---|
| OpenSearch が `localhost:9200` で起動している | `curl localhost:9200` でレスポンスが返ること |
| `ingest-attachment` プラグインが有効 | `curl localhost:9200/_cat/plugins` に `ingest-attachment` が含まれること |
| `analysis-kuromoji` プラグインが有効 | `curl localhost:9200/_cat/plugins` に `analysis-kuromoji` が含まれること |

> OpenSearch の起動確認時に `command not found` が出る場合は `PATH` を追加してください。
> ```bash
> export PATH=$PATH:/opt/podman/bin:/usr/local/bin
> ```

---

### Step 1 — 登録対象の文書を用意する

登録したい PDF/Office ファイルが入ったディレクトリのパスを控えておきます（後述の Step 3 で指定）。

---

### Step 2 — （必要に応じて）OpenSearch エンドポイントを設定する

`localhost:9200` 以外のエンドポイントを使う場合は環境変数を設定します。

```bash
export OS_URL=http://localhost:9200   # 既定値のため省略可
```

---

### Step 3 — インデックスを作成して文書を登録する

リポジトリルートから実行します。

```bash
# サンプルファイル（documents/ ディレクトリ）を登録する場合（引数省略で既定値を使用）
./ingest/ingest_documents.sh

# 任意のディレクトリを指定する場合
./ingest/ingest_documents.sh /path/to/your/documents
```

スクリプトは内部で以下を自動実行します（再実行しても安全）。

| ステップ | 内容 |
|---|---|
| ① Ingest Pipeline 作成 | `doc-attachment` パイプラインを PUT（すでに存在する場合は上書き） |
| ② インデックス再作成 | `ja-documents` を DELETE → PUT（**既存データは消えます**） |
| ③ 文書の送信・登録 | ディレクトリ内の対象ファイルを 1 件ずつ OpenSearch に送信 |

**対応拡張子**: `pdf` / `pptx` / `ppt` / `docx` / `doc` / `xlsx` / `xls`（大文字・小文字どちらでも可）

正常終了時の出力例:

```
indexed: kyoto-travel-guide.pdf
indexed: opensearch-intro.pdf
indexed: security-policy.pdf
indexed: sales-strategy.pptx
done: 4 file(s)
```

---

### Step 4 — インデックスが作成されたことを確認する

```bash
# ドキュメント数を確認
curl -s localhost:9200/ja-documents/_count | python3 -m json.tool

# 全文検索を試す（kuromoji で形態素解析されたテキストを検索）
curl -s localhost:9200/ja-documents/_search \
  -H 'Content-Type: application/json' \
  -d '{"query": {"match": {"attachment.content": "OpenSearch"}}}' \
  | python3 -m json.tool
```

---

### トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `curl: (7) Failed to connect` | OpenSearch が起動していない。起動後に再試行する |
| `{"error":{"type":"parse_exception"...}}` | 対象ディレクトリが空または対応外の拡張子しかない |
| `{"error":{"type":"mapper_parsing_exception"...}}` | インデックスのマッピングと送信データの型が不一致。スクリプトを再実行してインデックスを再作成する |
| `done: 0 file(s)` と表示される | 指定ディレクトリに対応拡張子のファイルがない。パスと拡張子を確認する |
| ファイルが登録されるが検索にヒットしない | `ingest-attachment` プラグインが無効で Tika によるテキスト抽出が行われていない可能性がある |

---

## `ingest_documents.sh` — 文書登録（BM25 版）

### 概要

指定ディレクトリ内の PDF/Office 文書を OpenSearch の
[`ingest-attachment`](https://opensearch.org/docs/latest/ingest-pipelines/processors/attachment/) パイプライン経由でテキスト抽出し、`ja-documents` インデックスへ登録します。

**Base64 はバイナリを JSON に乗せて HTTP 送信するための変換手段です。本文の抽出はスクリプト側では行わず、OpenSearch の `attachment` プロセッサ（Apache Tika）が担います。**

```
  PDF/pptx/docx（バイナリ）
        │
        │ base64 変換（JSON "data" フィールドに埋め込むため）
        ▼
  {"filename": "...", "data": "<Base64文字列>"}
        │
        │ PUT /{index}/_doc/{id}?pipeline=doc-attachment
        ▼
  ┌─────────────────────────────────────────────────────┐
  │  ingest pipeline: doc-attachment                    │
  │                                                     │
  │  1. attachment プロセッサ                            │
  │     "data"（Base64）を Tika でデコード・解析          │
  │     → attachment.content（プレーンテキスト）等を生成  │
  │                                                     │
  │  2. remove プロセッサ                                │
  │     "data"（Base64 生データ）を削除                   │
  └─────────────────────────────────────────────────────┘
        │
        ▼
  ja-documents インデックス
  （attachment.content を全文検索: ja_analyzer / kuromoji）
```

### 実行方法

```bash
# リポジトリルートから実行
./ingest/ingest_documents.sh [ディレクトリ]
```

| 引数 | 既定値 | 説明 |
|---|---|---|
| `ディレクトリ` | `ingest/documents/` | 登録対象ファイルが入ったディレクトリ |

**環境変数**

| 変数 | 既定値 | 説明 |
|---|---|---|
| `OS_URL` | `http://localhost:9200` | OpenSearch エンドポイント |

### 対応拡張子

`pdf` / `pptx` / `ppt` / `docx` / `doc` / `xlsx` / `xls`（大文字・小文字どちらでも可）

### 処理ステップ

1. **Ingest Pipeline 作成** — `doc-attachment` パイプラインを PUT する。
   - `attachment` プロセッサ: `data` フィールド（Base64）を Tika でデコード・解析し、`attachment.content`（本文テキスト）等を生成する。**本文抽出はここで行われる。**
   - `remove` プロセッサ: `data` フィールド（Base64 生データ）を削除し、テキストだけをインデックスに残す。
2. **インデックス再作成** — `ja-documents` を DELETE → PUT する（べき等な再実行を保証）。
   - `ja_analyzer`（kuromoji ベース）を設定。
   - `attachment.content` / `attachment.title` に `ja_analyzer` を適用。
3. **ファイル送信・登録** — ディレクトリをグロブし、1 件ずつ PUT `/{index}/_doc/{id}?pipeline=doc-attachment&refresh=true` で登録。
   - バイナリファイルを JSON の `"data"` フィールドに埋め込むため Base64 に変換してから送信する。テキスト抽出はスクリプト側では行わない。
   - ドキュメント ID はファイル名を URL パーセントエンコードしたもの。
   - JSON ペイロードのファイル名は `json.dumps` でエスケープ済み。

### インデックスのマッピング

| フィールド | 型 | 説明 |
|---|---|---|
| `filename` | `keyword` | 元のファイル名 |
| `attachment.content` | `text` (ja_analyzer) | Tika が抽出した本文 |
| `attachment.title` | `text` (ja_analyzer) | ファイルメタデータのタイトル |
| `attachment.content_type` | `keyword` | MIME タイプ |
| `attachment.content_length` | `long` | 本文の文字数 |
| `attachment.language` | `keyword` | Tika が判定した言語コード |

### 出力例

```
indexed: kyoto-travel-guide.pdf
indexed: opensearch-intro.pdf
indexed: security-policy.pdf
indexed: sales-strategy.pptx
done: 4 file(s)
```

---

## `setup_vector_search.sh` — ML Commons モデルのデプロイ

`ingest_documents_knn.sh` を実行する前に一度だけ実行するセットアップスクリプトです。
IBM の多言語埋め込みモデル [`ibm-granite/granite-embedding-107m-multilingual`](https://huggingface.co/ibm-granite/granite-embedding-107m-multilingual)（384 次元・日本語を含む 12 言語対応・Apache 2.0）を、
ONNX(fp32) のカスタムモデルとして ML Commons に登録・デプロイします。

> **前提**: Podman VM のメモリは **4GB** で動作します（実測。デプロイ・登録とも OOM なし）。
> ダウンロード（約 428MB）のためインターネット接続が必要です。
>
> ONNX は IBM 公式リポジトリの `model.onnx`（fp32）を使い、SHA-256 を検証します。
> 出力は `logits`（トークンごとの 384 次元）なので、ML Commons 側で `pooling_mode: CLS` / `normalize_result: true` を指定します。

### 実行方法

```bash
./ingest/setup_vector_search.sh
```

**環境変数**

| 変数 | 既定値 | 説明 |
|---|---|---|
| `OS_URL` | `http://localhost:9200` | OpenSearch エンドポイント |
| `MODEL_HOST` | `host.containers.internal` | OpenSearch コンテナから見たホストのアドレス |
| `MODEL_PORT` | `8765` | モデル配信用の一時 HTTP サーバーのポート |
| `WORK_DIR` | `ingest/.model-cache` | ダウンロードした ONNX・zip の保存先（約 250MB。`.gitignore` 済み） |

### 処理ステップ

| ステップ | 内容 |
|---|---|
| [1/5] ML Commons クラスタ設定 | `only_run_on_ml_node: false` / メモリ閾値 99% 等を permanent 設定 |
| [2/5] モデル取得 | Hugging Face から ONNX と `tokenizer.json` を取得し、SHA-256 を検証して zip 化 |
| [3/5] 一時 HTTP サーバー起動 | ML Commons は URL からしか登録できないため、ホスト上で zip を配信（終了時に自動停止） |
| [4/5] モデル登録 | モデルグループ作成 → `_register`（`pooling_mode: none`、`space_type: cosinesimil`）。完了まで最大 10 分待機 |
| [5/5] モデルデプロイ | `_deploy` API でモデルをメモリに展開。完了まで最大 10 分待機 |

完了すると `MODEL_ID` が表示されます。次のステップでこの値を使います。

```
=== セットアップ完了 ===
MODEL_ID: <表示された ID をコピー>

次のステップ: 文書を ja-documents-knn インデックスへ登録する
  ./ingest/ingest_documents_knn.sh [ディレクトリ] <MODEL_ID>
```

### 内部実装メモ（`wait_task` 関数）

`wait_task` 関数は進捗メッセージを **stderr** に、`model_id` 値のみを **stdout** に出力します。
`MODEL_ID=$(wait_task ...)` のコマンド置換が stdout だけを取得するため、
進捗メッセージを stdout に混在させると `MODEL_ID` が壊れてデプロイが失敗します。
この関数を改変する際は必ず `>&2` を維持してください。

### トラブルシューティング

| 症状 | 原因と対処 |
|---|---|
| `[4/5]` で `Connection refused` の `FAILED` | コンテナからホストの一時 HTTP サーバーに届いていない。`MODEL_HOST` を確認する（Podman なら `host.containers.internal`）。`podman exec opensearch-node1 curl -r 0-9 http://host.containers.internal:8765/granite-embedding-107m-onnx.zip` で疎通を確認する |
| `[5/5]` の途中で OpenSearch が落ちる（`podman ps` が `Exited (137)`） | Podman VM のメモリ不足。4GB 未満なら 4GB 以上に増設する。再起動後に `DEPLOY_FAILED` のモデルが残るので、スクリプトを再実行する |
| `podman` が `connection refused` / gvproxy が `address already in use` | `rm -f $TMPDIR/podman/*.sock` のあと `podman machine stop && podman machine start` |
| `SHA-256 が一致しません` | ダウンロードが壊れている。`ingest/.model-cache/pkg-granite/granite-embedding-107m.onnx` を削除して再実行する |
| `[4/5]` `[5/5]` で止まったまま進まない | 最大 10 分（120回 × 5秒）待機する |
| `FAILED` が表示される | ML Commons の設定（ステップ 1）が反映されていない。再実行する |
| セットアップ後に `ingest_documents_knn.sh` が「モデルが見つからない」と言う | デプロイが完了していない。`curl localhost:9200/_plugins/_ml/models/<MODEL_ID>` で `model_state` が `DEPLOYED` になっているか確認する |
| `.plugins-ml-model` が大量のディスクを使っている | モデルのウェイトデータ（約 130MB）が格納されている。不要なら `DELETE /.plugins-ml-model,.plugins-ml-task,.plugins-ml-model-group,.plugins-ml-config` で削除可能（次回 `setup_vector_search.sh` で再作成される） |

---

## `ingest_documents_knn.sh` — 文書登録（ベクトル検索対応版）

BM25 版と同じ文書を `ja-documents-knn` インデックスへ登録し、
さらに [`text_embedding`](https://opensearch.org/docs/latest/ingest-pipelines/processors/text-embedding/) プロセッサでベクトルを生成します。

### 実行方法

```bash
./ingest/ingest_documents_knn.sh [ディレクトリ] [MODEL_ID]
```

| 引数 | 既定値 | 説明 |
|---|---|---|
| `ディレクトリ` | `ingest/documents/` | 登録対象ファイルが入ったディレクトリ |
| `MODEL_ID` | 環境変数 `OPENSEARCH_MODEL_ID` / 自動検出 | 埋め込みモデルの ID |

**前提条件**: `setup_vector_search.sh` でモデルがデプロイ済みであること（Granite Embedding 107M Multilingual、384 次元）。

### MODEL_ID の解決順序

1. 第 2 引数 `[MODEL_ID]`
2. 環境変数 `OPENSEARCH_MODEL_ID`
3. ML Commons に問い合わせて `DEPLOYED` 状態のモデルを自動検出（`_source.model_id` フィールドを優先。`_id` はチャンク ID になる場合があるため使わない）

> **注意**: 自動検出は `DEPLOYED` のモデルを **先頭 1 件** 取るだけです。MiniLM など別モデルが残っていると
> 次元の違うモデルを拾い、`dimension` 不一致で登録に失敗します。複数モデルがある場合は第 2 引数で `MODEL_ID` を明示するか、
> 不要なモデルを `_undeploy` → `DELETE` してください。

### BM25 版との主な違い

| 項目 | `ingest_documents.sh` | `ingest_documents_knn.sh` |
|---|---|---|
| インデックス名 | `ja-documents` | `ja-documents-knn` |
| パイプライン名 | `doc-attachment` | `doc-attachment-knn` |
| knn 設定 | なし | `index.knn: true`, `knn_vector` フィールド追加 |
| ベクトルフィールド | なし | `chunks_embedding`（nested）配下の `knn`（次元: 384, HNSW/Lucene, `cosinesimil`） |
| 追加プロセッサ | なし | `script` + `text_chunking`（`fixed_char_length`）+ `text_embedding` |

> **注意**: `text_chunking` / `text_embedding` プロセッサはドット記法のネストフィールド
> （`attachment.content`）を直接参照できないため、スクリプトプロセッサで
> 一旦 `_content_tmp` にコピーしてから処理し、登録後に削除しています。

### チャンク分割

Granite の最大入力は 512 トークン（`max_position_embeddings=514`）のため、本文を `text_chunking` で分割し、
**チャンクごとにベクトル化**して `chunks_embedding`（`nested`）に保存します。1 文書 = 1 ドキュメントのままで、
ベクトルだけがチャンク数ぶん配列で入ります。

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `CHUNK_CHAR_LIMIT` | `500` | 1 チャンクの文字数 |
| `CHUNK_OVERLAP` | `0.1` | チャンク間の重複率 |

- アルゴリズムは `fixed_char_length`。`fixed_token_length` は `standard` 等の空白区切りトークナイザーしか選べず、
  日本語では 1 チャンクが 1,000 トークン超になる（URL が多い文書など）ため使わない
- 手元の 16 PDF（823 チャンク）では、500 文字のチャンクは最大 336 トークン・平均約 157 トークンで、512 を超えるものはなかった
- チャンクのテキスト（`chunks`）は `index: false` で保持するだけ。ハイライト用途に使える
- 検索は `nested` クエリで包み、`score_mode: max`（最もよく一致したチャンクの値が文書スコア）を使う。
  MCP の `neural_search` / `hybrid_search` は `vector_field: chunks_embedding.knn` と `nested_path: chunks_embedding` を指定する
- チャンク数が多い文書は登録に時間がかかる（16 PDF で約 31 秒）

---

## `make_samples.py` — サンプル文書の生成

`documents/` ディレクトリに日本語サンプルファイルを生成するスクリプトです。

```bash
.venv-pdf/bin/python ingest/make_samples.py
```

**依存ライブラリ**（`.venv-pdf` 仮想環境に収録; git 管理外）

| ライブラリ | 用途 |
|---|---|
| `reportlab` | PDF 生成 |
| `python-pptx` | PPTX 生成 |

**生成されるファイル**

| ファイル | 内容 |
|---|---|
| `documents/kyoto-travel-guide.pdf` | 京都観光ガイド |
| `documents/opensearch-intro.pdf` | OpenSearch 入門ガイド |
| `documents/security-policy.pdf` | 情報セキュリティ方針 |
| `documents/sales-strategy.pptx` | 新製品発表資料 |
| `documents/opensearch-training.pptx` | OpenSearch 研修スライド |

> **TTF 埋め込みについて**: reportlab で PDF を生成する際、フォントを埋め込まないと
> Tika（ingest-attachment が内部で使用）が `font is null` NPE を発生させ解析に失敗します。
> スクリプトは `/Library/Fonts/Arial Unicode.ttf` を埋め込んでこれを回避しています。
> CID フォント（`HeiseiKakuGo-W5` など）では同問題が再現するため使用していません。

---

## 既知の制約・落とし穴

### `remove_binary` は OpenSearch 非対応
Elasticsearch の `attachment` プロセッサには `remove_binary` オプションがありますが、
OpenSearch 版は非対応で指定すると 400 エラーになります。
代わりに `remove` プロセッサで `data` フィールドを明示的に削除しています。

### `ja_analyzer` の定義が重複している
`ja_analyzer`（kuromoji）の定義は以下の 2 か所に重複しています。変更時は**両方**を更新してください。

- `ingest/ingest_documents.sh`（`ja-documents` 用）
- `ingest/ingest_documents_knn.sh`（`ja-documents-knn` 用）

### インデックスは毎回 DELETE して再作成される
`ingest_documents.sh` および `ingest_documents_knn.sh` はべき等な再実行のために
インデックスを DROP → CREATE します。既存データは消えます。

### OpenSearch が起動していることを確認する
```bash
export PATH=$PATH:/opt/podman/bin:/usr/local/bin
curl localhost:9200
```
起動に数十秒かかる場合があります。
