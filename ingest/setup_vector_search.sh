#!/usr/bin/env bash
# Neural Search (ML Commons) モデルセットアップスクリプト
# IBM Granite Embedding 107M Multilingual（多言語・384 次元）を ONNX カスタムモデルとして登録・デプロイする。
#
# 使い方: ./ingest/setup_vector_search.sh
#
# 完了後、MODEL_ID が表示される。
# 文書の登録は ingest_documents_knn.sh を使う。
#   ./ingest/ingest_documents_knn.sh [ディレクトリ] [MODEL_ID]
#
# 処理の流れ:
#   1. Hugging Face（ibm-granite 公式）から ONNX(fp32) と tokenizer.json をダウンロード
#   2. zip に固め、SHA-256 を計算
#   3. ホスト上の一時 HTTP サーバーで配信（ML Commons は URL からのみ登録できる）
#   4. ML Commons に登録 → デプロイ
#
# 環境変数:
#   OS_URL        OpenSearch エンドポイント（既定 http://localhost:9200）
#   MODEL_HOST    コンテナから見たホストのアドレス（既定 host.containers.internal）
#   MODEL_PORT    一時 HTTP サーバーのポート（既定 8765）
#   WORK_DIR      ダウンロード・zip の作業ディレクトリ（既定 ingest/.model-cache）
set -euo pipefail

OS=${OS_URL:-http://localhost:9200}
H='Content-Type: application/json'

MODEL_NAME="ibm-granite/granite-embedding-107m-multilingual"
MODEL_VERSION="1.0.0"
EMBEDDING_DIM=384
HF_BASE="https://huggingface.co/ibm-granite/granite-embedding-107m-multilingual/resolve/main"
ONNX_FILE="model.onnx"                       # fp32（約 428MB）
ONNX_SHA256="387e6f91dce3c651cb3dc06661d74fb1d3947f20ed9c3ecf49d2b3b77086b954"

MODEL_HOST=${MODEL_HOST:-host.containers.internal}
MODEL_PORT=${MODEL_PORT:-8765}
WORK_DIR=${WORK_DIR:-"$(cd "$(dirname "$0")" && pwd)/.model-cache"}
ZIP_NAME="granite-embedding-107m-onnx.zip"

HTTP_PID=""
cleanup() { [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null || true; }
trap cleanup EXIT

# wait_task <task_id> <label>
# stdout に model_id のみ出力する。進捗メッセージは stderr に出す。
wait_task() {
  local task_id="$1"
  local label="$2"
  echo -n "$label ..." >&2
  for i in $(seq 1 120); do
    resp=$(curl -s "$OS/_plugins/_ml/tasks/$task_id")
    state=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))")
    if [ "$state" = "COMPLETED" ]; then
      model_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('model_id',''))")
      echo " COMPLETED (model_id: $model_id)" >&2
      echo "$model_id"   # stdout にのみ model_id を出力
      return 0
    elif [ "$state" = "FAILED" ]; then
      echo " FAILED" >&2
      echo "$resp" | python3 -m json.tool >&2
      exit 1
    fi
    echo -n "." >&2
    sleep 5
  done
  echo " TIMEOUT" >&2
  exit 1
}

# 1. ML Commons クラスタ設定
echo "=== [1/5] ML Commons クラスタ設定 ==="
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

# 2. モデルのダウンロードと zip 作成
echo "=== [2/5] モデル取得: $MODEL_NAME ==="
mkdir -p "$WORK_DIR/pkg-granite"
if [ ! -f "$WORK_DIR/pkg-granite/granite-embedding-107m.onnx" ]; then
  curl -fL --progress-bar -o "$WORK_DIR/pkg-granite/granite-embedding-107m.onnx" "$HF_BASE/$ONNX_FILE"
fi
actual_sha=$(shasum -a 256 "$WORK_DIR/pkg-granite/granite-embedding-107m.onnx" | awk '{print $1}')
if [ "$actual_sha" != "$ONNX_SHA256" ]; then
  echo "エラー: ONNX の SHA-256 が一致しません (expected=$ONNX_SHA256 actual=$actual_sha)" >&2
  echo "$WORK_DIR/pkg-granite/granite-embedding-107m.onnx を削除して再実行してください。" >&2
  exit 1
fi
[ -f "$WORK_DIR/pkg-granite/tokenizer.json" ] || curl -fL -s -o "$WORK_DIR/pkg-granite/tokenizer.json" "$HF_BASE/tokenizer.json"
rm -f "$WORK_DIR/$ZIP_NAME"
(cd "$WORK_DIR/pkg-granite" && zip -q "../$ZIP_NAME" granite-embedding-107m.onnx tokenizer.json)
ZIP_SHA=$(shasum -a 256 "$WORK_DIR/$ZIP_NAME" | awk '{print $1}')
echo "zip 作成完了 ($ZIP_NAME, sha256: $ZIP_SHA)"

# 3. 一時 HTTP サーバー
echo "=== [3/5] 一時 HTTP サーバー起動 (port $MODEL_PORT) ==="
(cd "$WORK_DIR" && exec python3 -m http.server "$MODEL_PORT" --bind 0.0.0.0 >/dev/null 2>&1) &
HTTP_PID=$!
sleep 2
kill -0 "$HTTP_PID" 2>/dev/null || { echo "エラー: ポート $MODEL_PORT を使用できません" >&2; exit 1; }
echo "起動完了 (pid: $HTTP_PID)"

# 4. モデル登録
echo "=== [4/5] モデル登録 ==="
group_resp=$(curl -sf -XPOST "$OS/_plugins/_ml/model_groups/_register" -H "$H" -d "{
  \"name\": \"granite-embedding-107m-group-$(date +%s)\",
  \"description\": \"granite-embedding-107m-multilingual (ONNX fp32)\"
}")
GROUP_ID=$(echo "$group_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['model_group_id'])")

# pooling_mode=CLS / normalize_result=true: Granite の sentence-transformers 構成（1_Pooling=CLS, 2_Normalize）に合わせる。
# ONNX の先頭出力 logits（トークンごとの 384 次元）に対して ML Commons 側でプーリングと正規化を行う。
register_resp=$(curl -sf -XPOST "$OS/_plugins/_ml/models/_register" -H "$H" -d "{
  \"name\": \"$MODEL_NAME\",
  \"version\": \"$MODEL_VERSION\",
  \"model_group_id\": \"$GROUP_ID\",
  \"description\": \"granite-embedding-107m-multilingual ONNX fp32\",
  \"function_name\": \"TEXT_EMBEDDING\",
  \"model_format\": \"ONNX\",
  \"model_content_hash_value\": \"$ZIP_SHA\",
  \"model_config\": {
    \"model_type\": \"xlm-roberta\",
    \"embedding_dimension\": $EMBEDDING_DIM,
    \"framework_type\": \"sentence_transformers\",
    \"pooling_mode\": \"CLS\",
    \"normalize_result\": true,
    \"additional_config\": { \"space_type\": \"cosinesimil\" }
  },
  \"url\": \"http://$MODEL_HOST:$MODEL_PORT/$ZIP_NAME\"
}")
register_task_id=$(echo "$register_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])")
MODEL_ID=$(wait_task "$register_task_id" "登録待機")

# 5. モデルデプロイ
echo "=== [5/5] モデルデプロイ ==="
deploy_resp=$(curl -sf -XPOST "$OS/_plugins/_ml/models/$MODEL_ID/_deploy")
deploy_task_id=$(echo "$deploy_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['task_id'])")
wait_task "$deploy_task_id" "デプロイ待機" >/dev/null

echo ""
echo "=== セットアップ完了 ==="
echo "MODEL_ID: $MODEL_ID"
echo ""
echo "次のステップ: 文書を ja-documents-knn インデックスへ登録する"
echo "  ./ingest/ingest_documents_knn.sh [ディレクトリ] $MODEL_ID"
echo ""
echo "Neural Search 例（MCP ツール）:"
echo "  mcp__opensearch-readonly__neural_search"
echo "    index: ja-documents-knn"
echo "    query_text: \"検索したい内容\""
echo "    model_id: $MODEL_ID"
echo "    vector_field: chunks_embedding.knn"
echo "    nested_path: chunks_embedding"
