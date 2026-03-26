#!/usr/bin/env bash
# k8s-run.sh - Kubernetes CronJob 管理入口
#
# 用法:
#   ./k8s-run.sh                                                      # 为所有 enabled repo 创建/更新 CronJob
#   ./k8s-run.sh https://github.com/user/repo                         # 单个 repo
#   ./k8s-run.sh --env .env.prod [repo_url]                           # 指定 env 文件（走 Secret）
#   ./k8s-run.sh --env .env.m2.5 --name my-cj [repo_url]             # env 直接注入 pod，自定义名称，无需 Secret
#   ./k8s-run.sh --env .env.x --prompt agent/auto-iterate-prompt.txt  # 指定 prompt 文件
#   ./k8s-run.sh --env .env.x --mode autoresearch                     # autoresearch 模式
#   ./k8s-run.sh --env .env.x --mode custom --prompt my-prompt.txt    # 自定义 prompt 模式
#   ./k8s-run.sh --update-secret                                      # 用当前 .env 更新 K8s Secret
#   ./k8s-run.sh --status                                             # 查看 CronJob、Job、Pod 状态
#   ./k8s-run.sh --delete                                             # 删除所有 CronJob
#   ./k8s-run.sh --logs                                               # 查看最近 Pod 的完整日志
#   ./k8s-run.sh --logs -f                                            # 实时跟踪最近 Pod 的日志
#   ./k8s-run.sh --logs <pod-name>                                    # 查看指定 Pod 的日志
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
CRONJOB_NAME=""
PROMPT_FILE=""
MODE_FLAG=""

# 解析 --env / --name / --prompt / --mode 参数（支持出现在任意位置）
REMAINING_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        --name)
            CRONJOB_NAME="$2"
            shift 2
            ;;
        --prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        --mode)
            MODE_FLAG="$2"
            shift 2; continue
            ;;
        *)
            REMAINING_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"

# 加载 env 文件：先加载默认 .env（作为基础层），再用 --env 文件覆盖
# 这样 .env 中的 GIT_TOKEN 等在使用 --env 时依然可用
if [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a; source "${SCRIPT_DIR}/.env"; set +a
fi
if [ -n "${ENV_FILE}" ]; then
    if [ ! -f "${ENV_FILE}" ]; then
        echo "❌ env 文件不存在: ${ENV_FILE}"
        exit 1
    fi
    echo "[INFO] 加载 env 文件: ${ENV_FILE}"
    set -a; source "${ENV_FILE}"; set +a
fi

# 处理 --prompt：读取本地文件内容，设为 CLAUDE_PROMPT 环境变量
if [ -n "${PROMPT_FILE}" ]; then
    if [ ! -f "${PROMPT_FILE}" ]; then
        echo "❌ prompt 文件不存在: ${PROMPT_FILE}"
        exit 1
    fi
    export CLAUDE_PROMPT
    CLAUDE_PROMPT="$(cat "${PROMPT_FILE}")"
    echo "[INFO] 加载 prompt 文件: ${PROMPT_FILE} (${#CLAUDE_PROMPT} 字符)"
fi

# 处理 --mode
if [ -n "${MODE_FLAG}" ]; then
    export PIPELINE_MODE="${MODE_FLAG}"
    echo "[INFO] 模式: PIPELINE_MODE=${PIPELINE_MODE}"
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
    shift
    FOLLOW=""
    TARGET_POD=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f|--follow) FOLLOW="-f"; shift ;;
        *)           TARGET_POD="$1"; shift ;;
      esac
    done

    if [ -z "${TARGET_POD}" ]; then
      TARGET_POD=$(kubectl get pods -n "${NAMESPACE}" \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || echo "")
    fi

    if [ -z "${TARGET_POD}" ]; then
      echo "❌ 没有找到 Pod"
      exit 1
    fi
    echo "=== Pod: ${TARGET_POD} ==="
    # shellcheck disable=SC2086
    if ! kubectl logs -n "${NAMESPACE}" "${TARGET_POD}" ${FOLLOW} 2>/dev/null; then
      echo "⚠️  kubectl logs 不可用（Docker Desktop GC），尝试: ./k8s-run.sh --logs-history"
    fi
    ;;

  --logs-history)
    # 从 cargo-cache PVC 读取持久化日志（绕过 Docker Desktop GC 问题）
    shift
    N="${1:-1}"  # 默认显示最近 1 个日志文件
    echo "=== 从 PVC 读取最近 ${N} 个历史日志 ==="
    # 用 python3 镜像替代 busybox sh glob，避免 JSON 转义和 glob 展开问题
    kubectl run "log-reader-$$" -n "${NAMESPACE}" --rm -i --restart=Never \
      --image=python:3.11-alpine \
      --overrides="{\"spec\":{\"volumes\":[{\"name\":\"cargo\",\"persistentVolumeClaim\":{\"claimName\":\"cargo-registry-cache\"}}],\"containers\":[{\"name\":\"reader\",\"image\":\"python:3.11-alpine\",\"command\":[\"python3\",\"-c\",\"import os,sys;d='/cargo/pipeline-logs';files=sorted([os.path.join(d,f) for f in os.listdir(d) if f.endswith('.log') and f not in ('test.log','probe.log')],key=os.path.getmtime,reverse=True)[:${N}];[print(f'=== {f} ===') or print(open(f).read()) for f in files]\"],\"volumeMounts\":[{\"name\":\"cargo\",\"mountPath\":\"/cargo\"}]}]}}" \
      2>/dev/null || echo "❌ 无法读取 PVC 日志（PVC 可能不包含日志）"
    ;;

  --update-secret)
    # 从已加载的 env 中读取 token，优先用 ANTHROPIC_AUTH_TOKEN
    API_KEY="${ANTHROPIC_AUTH_TOKEN:-${ANTHROPIC_API_KEY:-}}"
    GIT_TOK="${GIT_TOKEN:-${GITHUB_TOKEN:-}}"

    if [ -z "${API_KEY}" ]; then
      echo "❌ 未找到 ANTHROPIC_AUTH_TOKEN 或 ANTHROPIC_API_KEY"
      exit 1
    fi
    if [ -z "${GIT_TOK}" ]; then
      echo "❌ 未找到 GIT_TOKEN 或 GITHUB_TOKEN"
      exit 1
    fi

    # 用 kubectl create secret --dry-run + apply 实现幂等更新
    kubectl create secret generic claude-pipeline-secrets \
      --namespace="${NAMESPACE}" \
      --from-literal=ANTHROPIC_API_KEY="${API_KEY}" \
      --from-literal=GIT_TOKEN="${GIT_TOK}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "✅ Secret 已更新（ANTHROPIC_AUTH_TOKEN → ANTHROPIC_API_KEY）"
    ;;

  --help|-h)
    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# //' | sed 's/^#//'
    ;;

  *)
    EXTRA_ARGS=()
    # 指定了 env 文件 → 用 inline 模式（env 直接写入 pod，不用 Secret）
    if [ -n "${ENV_FILE}" ]; then
        EXTRA_ARGS+=("--inline-env")
    fi
    # 指定了自定义 CronJob 名称
    if [ -n "${CRONJOB_NAME}" ]; then
        EXTRA_ARGS+=("--name" "${CRONJOB_NAME}")
    fi
    python3 "${SCRIPT_DIR}/k8s/render_and_apply.py" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" "$@"
    ;;
esac
