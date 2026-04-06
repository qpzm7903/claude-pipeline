#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== LiteLLM Proxy 安装脚本 ==="
echo ""

ENV_FILE="${1:-}"
if [[ -z "$ENV_FILE" ]]; then
    if [[ -f "$SCRIPT_DIR/../.env.litellm" ]]; then
        ENV_FILE="$SCRIPT_DIR/../.env.litellm"
    else
        echo "用法: $0 <env-file>"
        echo ""
        echo "创建 .env.litellm 文件，内容示例:"
        cat << 'EOF'
LITELLM_MASTER_KEY=sk-your-master-key
OPENAI_API_KEY=sk-xxx
ANTHROPIC_API_KEY=sk-ant-xxx
DASHSCOPE_API_KEY=sk-xxx
EOF
        exit 1
    fi
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ env 文件不存在: $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

: "${LITELLM_MASTER_KEY:=""}"
: "${DASHSCOPE_APPS_API_KEY:="${DASHSCOPE_API_KEY:-}"}"
if [[ -z "$LITELLM_MASTER_KEY" ]]; then
    echo "❌ 缺少 LITELLM_MASTER_KEY"
    exit 1
fi

echo "[1/3] 部署 PostgreSQL..."
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: litellm-postgres-pvc
  namespace: litellm
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm-postgres
  namespace: litellm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm-postgres
  template:
    metadata:
      labels:
        app: litellm-postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_USER
          value: litellm
        - name: POSTGRES_PASSWORD
          value: litellm
        - name: POSTGRES_DB
          value: litellm
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: litellm-postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: litellm-postgres
  namespace: litellm
spec:
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: litellm-postgres
EOF

echo "[2/3] 部署/更新 LiteLLM..."
kubectl apply -f "$SCRIPT_DIR/litellm.yaml"

echo "[3/3] 更新 Secret..."
kubectl wait --for=condition=Ready pod -l app=litellm-postgres -n litellm --timeout=120s 2>/dev/null || true
kubectl create secret generic litellm-secrets \
    --namespace=litellm \
    --from-literal=LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY}" \
    --from-literal=LITELLM_SALT_KEY="${LITELLM_SALT_KEY:-sk-litellm-salt-key-local-dev}" \
    --from-literal=DASHSCOPE_APPS_API_KEY="${DASHSCOPE_APPS_API_KEY:-}" \
    --from-literal=DASHSCOPE_API_KEY="${DASHSCOPE_API_KEY:-}" \
    --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "[INFO] 触发 LiteLLM 滚动重启以应用最新配置或镜像..."
kubectl rollout restart deployment litellm -n litellm || true

echo ""
echo "[INFO] 等待 Pod 就绪..."
kubectl rollout status deployment litellm -n litellm --timeout=180s || true

echo ""
echo "=== 安装完成 ==="
echo ""
echo "访问方式:"
echo "  地址: http://localhost:4000"
echo "  API 端点: http://localhost:4000/v1/chat/completions"
echo ""
echo "Port-forward:"
echo "  kubectl port-forward svc/litellm -n litellm 4000:4000"
echo ""
echo "测试请求:"
echo "  curl http://localhost:4000/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Authorization: Bearer ${LITELLM_MASTER_KEY}' \\"
echo "    -d '{\"model\": \"gpt-4o-mini\", \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}]}'"