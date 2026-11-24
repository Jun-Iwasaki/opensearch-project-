#!/usr/bin/env bash
# Neural Search (ML Commons) モデルセットアップスクリプト
# paraphrase-multilingual-MiniLM-L12-v2 を登録・デプロイする。
#
# 使い方: ./sample-data/setup_vector_search.sh
#
# 完了後、MODEL_ID が表示される。
# 文書の登録は ingest_documents_knn.sh を使う。
#   ./sample-data/ingest_documents_knn.sh [ディレクトリ] [MODEL_ID]
set -euo pipefail

OS=${OS_URL:-http://localhost:9200}
H='Content-Type: application/json'
MODEL_NAME="huggingface/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
MODEL_VERSION="1.0.1"

wait_task() {
  local task_id="$1"
  local label="$2"
  echo -n "$label ..."
  for i in $(seq 1 60); do
    resp=$(curl -s "$OS/_plugins/_ml/tasks/$task_id")
    state=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))")
    if [ "$state" = "COMPLETED" ]; then
      model_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model_id',''))")
      echo " COMPLETED (model_id: $model_id)"
      echo "$model_id"
      return 0
    elif [ "$state" = "FAILED" ]; then
      echo " FAILED"
      echo "$resp" | python3 -m json.tool >&2
      exit 1
    fi
    echo -n "."
    sleep 5
  done
  echo " TIMEOUT"
  exit 1
}

# 1. ML Commons クラスタ設定
echo "=== [1/3] ML Commons クラスタ設定 ==="
curl -sf -XPUT "$OS/_cluster/settings" -H "$H" -d '{
  "persistent": {
    "plugins.ml_commons.only_run_on_ml_node": false,
    "plugins.ml_commons.allow_registering_model_via_url": true,
    "plugins.ml_commons.model_access_control_enabled": false,
    "plugins.ml_commons.native_memory_threshold": 99,
    "plugins.ml_commons.jvm_heap_memory_threshold": 99
  }
}' >/dev/null
echo "設定完了"

# 2. モデル登録
echo "=== [2/3] モデル登録: $MODEL_NAME ==="
register_resp=$(curl -sf -XPOST "$OS/_plugins/_ml/models/_register" -H "$H" -d "{
  \"name\": \"$MODEL_NAME\",
  \"version\": \"$MODEL_VERSION\",
  \"model_format\": \"TORCH_SCRIPT\"
}")
register_task_id=$(echo "$register_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])")
MODEL_ID=$(wait_task "$register_task_id" "登録待機")

# 3. モデルデプロイ
echo "=== [3/3] モデルデプロイ ==="
deploy_resp=$(curl -sf -XPOST "$OS/_plugins/_ml/models/$MODEL_ID/_deploy")
deploy_task_id=$(echo "$deploy_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])")
wait_task "$deploy_task_id" "デプロイ待機" >/dev/null

echo ""
echo "=== セットアップ完了 ==="
echo "MODEL_ID: $MODEL_ID"
echo ""
echo "次のステップ: 文書を ja-documents-knn インデックスへ登録する"
echo "  ./sample-data/ingest_documents_knn.sh [ディレクトリ] $MODEL_ID"
echo ""
echo "Neural Search 例（MCP ツール）:"
echo "  mcp__opensearch-readonly__neural_search"
echo "    index: ja-documents-knn"
echo "    query_text: \"検索したい内容\""
echo "    model_id: $MODEL_ID"
echo "    vector_field: content_embedding"
