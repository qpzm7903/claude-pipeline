#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Claude Pipeline Kubernetes 安装脚本 ==="
echo ""

command -v kubectl &>/dev/null || {
    echo "❌ 需要安装 kubectl: brew install kubectl"
    exit 1
}

command -v docker &>/dev/null || {
    echo "❌ 需要安装 Docker: https://docs.docker.com/get-docker/"
    exit 1
}

ENV_FILE="${1:-}"
if [[ -z "$ENV_FILE" ]]; then
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        ENV_FILE="$PROJECT_DIR/.env"
        echo "[INFO] 使用默认 .env 文件"
    else
        echo "用法: $0 <env-file>"
        echo "示例: $0 .env.myconfig"
        echo ""
        echo "env 文件示例:"
        cat << 'EOF'
ANTHROPIC_AUTH_TOKEN=sk-xxx
ANTHROPIC_BASE_URL=https://api.anthropic.com
ANTHROPIC_MODEL=claude-sonnet-4-20250514
GIT_TOKEN=ghp_xxx
GIT_REPO_URL=https://github.com/owner/repo
EOF
        exit 1
    fi
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ env 文件不存在: $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

: "${ANTHROPIC_AUTH_TOKEN:=${ANTHROPIC_API_KEY:-}}"
: "${GIT_TOKEN:=${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
: "${GIT_REPO_URL:=""}"

if [[ -z "$ANTHROPIC_AUTH_TOKEN" ]]; then
    echo "❌ 缺少 ANTHROPIC_AUTH_TOKEN 或 ANTHROPIC_API_KEY"
    exit 1
fi

if [[ -z "$GIT_TOKEN" ]]; then
    echo "❌ 缺少 GIT_TOKEN 或 GITHUB_TOKEN"
    exit 1
fi

echo "[1/3] 构建 Docker 镜像..."
if ! docker images | grep -q "claude-pipeline-base"; then
    echo "  构建 base 镜像..."
    docker build -t claude-pipeline-base:latest -f "$PROJECT_DIR/agent/Dockerfile.base" "$PROJECT_DIR/agent/"
fi
docker build -t claude-pipeline-agent:latest "$PROJECT_DIR/agent/"

echo "[2/3] 部署 Kubernetes 资源..."
kubectl apply -f "$SCRIPT_DIR/all-in-one.yaml"

echo "[3/3] 创建 Secret..."
kubectl create secret generic claude-pipeline-secrets \
    --namespace=claude-pipeline \
    --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_AUTH_TOKEN" \
    --from-literal=GIT_TOKEN="$GIT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "$GIT_REPO_URL" ]]; then
    echo ""
    echo "[INFO] 部署 CronJob..."
    cd "$PROJECT_DIR"
    ./k8s-run.sh --env "$ENV_FILE" --name "$(basename "$GIT_REPO_URL" .git)"
fi

echo ""
echo "=== 安装完成 ==="
echo ""
echo "查看状态: ./k8s-run.sh --status"
echo "查看日志: ./k8s-run.sh --logs"
echo "手动触发: kubectl create job --from=cronjob/claude-pipeline-<name> manual-\$(date +%s) -n claude-pipeline"