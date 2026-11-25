#!/usr/bin/env bash
# PDF / Office 文書を ingest-attachment + text_embedding 経由で
# ja-documents-knn インデックスに登録する（ベクトル検索対応版）。
#
# 使い方:
#   ./ingest/ingest_documents_knn.sh [ディレクトリ] [MODEL_ID]
#
#   ディレクトリ: 既定 ingest/documents/
#   MODEL_ID    : 既定 環境変数 OPENSEARCH_MODEL_ID。
#                 未指定の場合は ML Commons からデプロイ済みモデルを自動検出する。
#
# 前提:
#   - OpenSearch が localhost:9200 で起動していること
#   - analysis-kuromoji プラグインが有効であること
#   - ingest-attachment プラグインが有効であること
#   - paraphrase-multilingual-MiniLM-L12-v2 相当のモデルがデプロイ済みであること
#     （未デプロイの場合は setup_vector_search.sh を先に実行する）
#
# 対象拡張子: pdf pptx ppt docx doc xlsx xls
set -euo pipefail

OS=${OS_URL:-http://localhost:9200}
DIR=${1:-"$(cd "$(dirname "$0")" && pwd)/documents"}
INDEX=ja-documents-knn
H='Content-Type: application/json'

# ---- MODEL_ID の解決 ----------------------------------------------------------
MODEL_ID=${2:-${OPENSEARCH_MODEL_ID:-}}

if [ -z "$MODEL_ID" ]; then
  echo "MODEL_ID が未指定のため、デプロイ済みモデルを自動検出します..."
  model_resp=$(curl -s -XGET "$OS/_plugins/_ml/models/_search" -H "$H" -d '{
    "query": { "term": { "model_state": "DEPLOYED" } },
    "_source": ["model_id"],
    "size": 1
  }')
  MODEL_ID=$(echo "$model_resp" | python3 -c "
import sys, json
data = json.load(sys.stdin)
hits = data.get('hits', {}).get('hits', [])
if not hits:
    print('')
else:
    # _id はチャンク ID になる場合があるため _source.model_id を優先する
    src = hits[0].get('_source', {})
    print(src.get('model_id') or hits[0]['_id'])
" 2>/dev/null || true)

  if [ -z "$MODEL_ID" ]; then
    echo "エラー: デプロイ済みの ML Commons モデルが見つかりません。" >&2
    echo "先に setup_vector_search.sh を実行してモデルをデプロイしてください。" >&2
    echo "または MODEL_ID を引数か環境変数 OPENSEARCH_MODEL_ID で指定してください。" >&2
    exit 1
  fi
  echo "検出された MODEL_ID: $MODEL_ID"
fi

# ---- 1. 取り込みパイプライン作成 -----------------------------------------------
# attachment: Base64 → テキスト抽出
# text_embedding: attachment.content → content_embedding（ベクトル）
# remove: Base64 の生データを削除
echo "=== [1/4] Ingest Pipeline 作成 ==="
# text_embedding プロセッサはネストフィールド（attachment.content）のドット記法を
# 解釈できないため、set で一旦トップレベルにコピーしてからベクトル化し、後で削除する。
curl -sf -XPUT "$OS/_ingest/pipeline/doc-attachment-knn" -H "$H" -d "{
  \"description\": \"PDF/Office文書の本文抽出とベクトル化\",
  \"processors\": [
    {
      \"attachment\": {
        \"field\": \"data\",
        \"target_field\": \"attachment\",
        \"indexed_chars\": -1
      }
    },
    {
      \"script\": {
        \"lang\": \"painless\",
        \"source\": \"ctx['_content_tmp'] = ctx['attachment']['content']\"
      }
    },
    {
      \"text_embedding\": {
        \"model_id\": \"$MODEL_ID\",
        \"field_map\": { \"_content_tmp\": \"content_embedding\" }
      }
    },
    {
      \"remove\": { \"field\": [\"data\", \"_content_tmp\"] }
    }
  ]
}" >/dev/null
echo "Pipeline 作成完了 (doc-attachment-knn, model_id: $MODEL_ID)"

# ---- 2. インデックス作成（作り直し）--------------------------------------------
echo "=== [2/4] インデックス作成: $INDEX ==="
curl -s -XDELETE "$OS/$INDEX" >/dev/null || true
curl -sf -XPUT "$OS/$INDEX" -H "$H" -d '{
  "settings": {
    "index.knn": true,
    "analysis": {
      "analyzer": {
        "ja_analyzer": {
          "type": "custom",
          "tokenizer": "kuromoji_tokenizer",
          "filter": [
            "kuromoji_baseform",
            "kuromoji_part_of_speech",
            "cjk_width",
            "ja_stop",
            "kuromoji_stemmer",
            "lowercase"
          ]
        }
      }
    }
  },
  "mappings": {
    "properties": {
      "filename": { "type": "keyword" },
      "content_embedding": {
        "type": "knn_vector",
        "dimension": 384,
        "method": {
          "name": "hnsw",
          "space_type": "l2",
          "engine": "lucene"
        }
      },
      "attachment": {
        "properties": {
          "content":        { "type": "text", "analyzer": "ja_analyzer" },
          "title":          { "type": "text", "analyzer": "ja_analyzer" },
          "content_type":   { "type": "keyword" },
          "content_length": { "type": "long" },
          "language":       { "type": "keyword" }
        }
      }
    }
  }
}' >/dev/null
echo "インデックス作成完了"

# ---- 3. ファイルを Base64 化して登録 -------------------------------------------
echo "=== [3/4] ファイル登録 ==="
shopt -s nullglob nocaseglob
count=0
for f in "$DIR"/*.{pdf,pptx,ppt,docx,doc,xlsx,xls}; do
  name=$(basename "$f")
  b64=$(base64 < "$f" | tr -d '\n')
  id=$(python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$name")
  jname=$(python3 -c 'import sys,json; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$name")
  printf '{"filename":%s,"data":"%s"}' "$jname" "$b64" \
    | curl -sf -XPUT "$OS/$INDEX/_doc/$id?pipeline=doc-attachment-knn&refresh=true" \
        -H "$H" --data-binary @- >/dev/null
  echo "indexed: $name"
  count=$((count+1))
done
echo "=== [4/4] 完了: $count ファイルを登録しました ==="

echo ""
echo "Neural Search 例:"
echo "  mcp__opensearch-readonly__neural_search"
echo "    index: $INDEX"
echo "    query_text: \"検索したい内容\""
echo "    model_id: $MODEL_ID"
echo "    vector_field: content_embedding"
