#!/usr/bin/env bash
# PDF / Office 文書を ingest-attachment 経由で ja-documents インデックスに登録する。
# 使い方: ./ingest/ingest_documents.sh [ディレクトリ(既定: ingest/documents)]
# 対象拡張子: pdf pptx docx xlsx (ppt doc xls も可)
set -euo pipefail

OS=${OS_URL:-http://localhost:9200}
DIR=${1:-"$(cd "$(dirname "$0")" && pwd)/documents"}
INDEX=ja-documents
H='Content-Type: application/json'

# 1. 取り込みパイプライン: Base64 の data から本文を抽出し、data は保存しない
curl -sf -XPUT "$OS/_ingest/pipeline/doc-attachment" -H "$H" -d '{
  "description": "PDF/Office文書から本文を抽出する",
  "processors": [
    { "attachment": {
        "field": "data",
        "target_field": "attachment",
        "indexed_chars": -1
    } },
    { "remove": { "field": "data" } }
  ]
}' >/dev/null

# 2. インデックス作成（作り直し）
curl -s -XDELETE "$OS/$INDEX" >/dev/null || true
curl -sf -XPUT "$OS/$INDEX" -H "$H" -d '{
  "settings": {
    "analysis": { "analyzer": { "ja_analyzer": {
      "type": "custom",
      "tokenizer": "kuromoji_tokenizer",
      "filter": ["kuromoji_baseform","kuromoji_part_of_speech","cjk_width","ja_stop","kuromoji_stemmer","lowercase"]
    } } }
  },
  "mappings": { "properties": {
    "filename":   { "type": "keyword" },
    "attachment": { "properties": {
      "content":        { "type": "text", "analyzer": "ja_analyzer" },
      "title":          { "type": "text", "analyzer": "ja_analyzer" },
      "content_type":   { "type": "keyword" },
      "content_length": { "type": "long" },
      "language":       { "type": "keyword" }
    } }
  } }
}' >/dev/null

# 3. ファイルを JSON ペイロードとして送信し、OpenSearch 側で本文を抽出・登録する
#
# JSON の "data" フィールドにはバイナリをそのまま入れられないため、
# Base64 に変換してテキストとして埋め込んで HTTP 送信する。
# 本文の抽出は OpenSearch の attachment プロセッサ（Apache Tika）が担い、
# スクリプト側はテキスト抽出を行わない。
#
# pipeline=doc-attachment によって OpenSearch 内で以下が行われる:
#   1. attachment プロセッサ: "data"（Base64）を Tika でデコード・解析し
#      attachment.content（プレーンテキスト）等を生成する
#   2. remove プロセッサ: "data"（Base64 生データ）を削除し、
#      attachment.content だけをインデックスに残す
shopt -s nullglob nocaseglob
count=0
for f in "$DIR"/*.{pdf,pptx,ppt,docx,doc,xlsx,xls}; do
  name=$(basename "$f")
  # バイナリを JSON に乗せるため Base64 に変換する（本文抽出は OpenSearch 側で行う）
  b64=$(base64 < "$f" | tr -d '\n')
  # ファイル名にスペース等を含むため、URL 用にパーセントエンコード / JSON 用にエスケープする
  id=$(python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$name")
  jname=$(python3 -c 'import sys,json; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$name")
  printf '{"filename":%s,"data":"%s"}' "$jname" "$b64" \
    | curl -sf -XPUT "$OS/$INDEX/_doc/$id?pipeline=doc-attachment&refresh=true" -H "$H" --data-binary @- >/dev/null
  echo "indexed: $name"
  count=$((count+1))
done
echo "done: $count file(s)"
