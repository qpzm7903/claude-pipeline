#!/usr/bin/env bash
# k8s-run.sh - Kubernetes CronJob 管理入口
#
# 用法:
#   ./k8s-run.sh                                    # 为所有 enabled repo 创建/更新 CronJob
#   ./k8s-run.sh https://github.com/user/repo       # 单个 repo
#   ./k8s-run.sh --env .env.prod [repo_url]         # 指定 env 文件
#   ./k8s-run.sh --status                           # 查看 CronJob、Job、Pod 状态
#   ./k8s-run.sh --delete                           # 删除所有 CronJob
#   ./k8s-run.sh --logs                             # 查看最近 Pod 的日志
#
# 前置条件:
#   1. kubectl 已配置并连接到目标集群
#   2. Docker 镜像已构建: docker build -t claude-pipeline-agent:latest ./agent/
#   3. Secret 已创建:
#        cp k8s/secret.yaml.example k8s/secret.yaml
#        kubectl apply -f k8s/secret.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="claude-pipeline"
ENV_FILE=""

# 解析 --env 参数（支持出现在任意位置）
REMAINING_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        *)
            REMAINING_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

# 加载 env 文件：优先用 --env 指定的，否则用默认 .env
if [ -n "${ENV_FILE}" ]; then
    if [ ! -f "${ENV_FILE}" ]; then
        echo "❌ env 文件不存在: ${ENV_FILE}"
        exit 1
    fi
    echo "[INFO] 加载 env 文件: ${ENV_FILE}"
    set -a; source "${ENV_FILE}"; set +a
elif [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a; source "${SCRIPT_DIR}/.env"; set +a
fi

# 读取 config.yaml 中的 namespace
if command -v python3 &>/dev/null && [ -f "${SCRIPT_DIR}/config/config.yaml" ]; then
    _ns=$(python3 -c "
import yaml
try:
    cfg = yaml.safe_load(open('${SCRIPT_DIR}/config/config.yaml'))
    print(cfg.get('kubernetes', {}).get('namespace', 'claude-pipeline'))
except Exception:
    print('claude-pipeline')
" 2>/dev/null || echo "claude-pipeline")
    NAMESPACE="${_ns}"
fi

case "${1:-}" in
  --status)
    echo "=== CronJobs ==="
    kubectl get cronjob -n "${NAMESPACE}" -l app.kubernetes.io/name=claude-pipeline \
      -o wide 2>/dev/null || echo "  (无 CronJob)"
    echo ""
    echo "=== Jobs (最近10个) ==="
    kubectl get jobs -n "${NAMESPACE}" \
      --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -11 || echo "  (无 Job)"
    echo ""
    echo "=== Pods (最近10个) ==="
    kubectl get pods -n "${NAMESPACE}" \
      --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -11 || echo "  (无 Pod)"
    ;;

  --delete)
    echo "删除所有 claude-pipeline CronJob..."
    kubectl delete cronjob -n "${NAMESPACE}" \
      -l app.kubernetes.io/name=claude-pipeline \
      --ignore-not-found=true
    echo "✅ 已删除"
    ;;

  --logs)
    POD=$(kubectl get pods -n "${NAMESPACE}" \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${POD}" ]; then
      echo "❌ 没有找到 Pod"
      exit 1
    fi
    echo "=== Pod: ${POD} ==="
    kubectl logs -n "${NAMESPACE}" "${POD}" --tail=100
    ;;

  --help|-h)
    sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# //' | sed 's/^#//'
    ;;

  *)
    python3 "${SCRIPT_DIR}/k8s/render_and_apply.py" "$@"
    ;;
esac
