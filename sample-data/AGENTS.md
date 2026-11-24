# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Overview

ローカル OpenSearch に日本語サンプルデータを登録するスクリプト群。テスト用 PDF/PPTX 生成 → インデックス登録の 2 ステップ構成。

## Commands

```bash
# サンプル文書を documents/ に生成（仮想環境は .venv-pdf を使う）
.venv-pdf/bin/python sample-data/make_samples.py

# BM25 用インデックスに登録（リポジトリルートから実行）
./sample-data/ingest_documents.sh [ディレクトリ]

# ベクトル検索用インデックスに登録（setup_vector_search.sh を先に実行必須）
./sample-data/ingest_documents_knn.sh [ディレクトリ] [MODEL_ID]

# ML Commons モデルのデプロイ（ingest_documents_knn.sh の前提）
./sample-data/setup_vector_search.sh
```

**環境変数**
- `OS_URL` — OpenSearch エンドポイント（既定: `http://localhost:9200`）
- `OPENSEARCH_MODEL_ID` — knn スクリプトのモデル ID（引数でも指定可）

## Critical Gotchas

### OpenSearch 非対応オプション
`attachment` プロセッサの `remove_binary` オプションは OpenSearch では **400 エラー**になる。代わりに `remove` プロセッサで `data` フィールドを明示的に削除する（両スクリプトで実施済み）。

### `text_embedding` のネストフィールド制限
`text_embedding` プロセッサはドット記法（`attachment.content`）を直接参照できない。`script` プロセッサで一旦 `_content_tmp` にコピーしてからベクトル化し、`remove` で削除する回避策を採用している（`ingest_documents_knn.sh`）。

### PDF には TTF フォント埋め込みが必須
reportlab で PDF を生成する際、TTF を埋め込まないと Tika が `font is null` NPE を起こして解析に失敗する。`make_samples.py` は `/Library/Fonts/Arial Unicode.ttf` を埋め込む。CID フォント（`HeiseiKakuGo-W5` など）では同問題が再現するため使用不可。

### インデックスは毎回 DROP → CREATE
`ingest_documents.sh` / `ingest_documents_knn.sh` はべき等な再実行のためインデックスを毎回削除・再作成する。**既存データはすべて消える**。

### `ja_analyzer` の定義が 2 箇所に重複
`ingest_documents.sh`（`ja-documents`）と `ingest_documents_knn.sh`（`ja-documents-knn`）の両方に kuromoji analyzer の定義がある。変更時は **両方**を更新すること。

## Architecture

```
make_samples.py         → documents/*.pdf / *.pptx
ingest_documents.sh     → ja-documents (BM25, kuromoji)
ingest_documents_knn.sh → ja-documents-knn (knn_vector dim=384, HNSW/Lucene)
setup_vector_search.sh  → paraphrase-multilingual-MiniLM-L12-v2 をデプロイ
```

## Index Schemas

| フィールド | BM25 | knn |
|---|---|---|
| `filename` | keyword | keyword |
| `attachment.content` | text (ja_analyzer) | text (ja_analyzer) |
| `attachment.title` | text (ja_analyzer) | text (ja_analyzer) |
| `content_embedding` | — | knn_vector (dim=384) |

ドキュメント ID はファイル名を URL パーセントエンコードしたもの（`python3 -c 'urllib.parse.quote(...)'`）。
