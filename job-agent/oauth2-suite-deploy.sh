#!/usr/bin/env bash
# oauth2-suite-deploy.sh — 串行部署 4 个 oauth2-* 任务并收集日志
#
# 流程: feature-dev → ut-gen → refactor → perf
# 之所以串行: 4 任务都 push 到同一仓库 (qpzm7903/job-demo)，
#            并发会因 fast-forward 拒绝而互相打架。
#
# 用法:
#   bash job-agent/oauth2-suite-deploy.sh                # 串行跑 4 任务
#   bash job-agent/oauth2-suite-deploy.sh feature-dev    # 只跑指定任务
#   bash job-agent/oauth2-suite-deploy.sh --dry-run      # 只组装 dist YAML，不 apply
#
# 前置:
#   - K8s namespace 'claude-pipeline' 已存在
#   - Secret 'litellm-bridge' (ANTHROPIC_API_KEY) 与 'github-token' (GIT_TOKEN) 已创建
#   - LiteLLM 已部署且 service 'litellm.litellm.svc.cluster.local:4000' 可达
#   - 镜像 'java-claude-pipeline:latest' 已存在于集群可见的 registry / 节点本地

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-claude-pipeline}"
LOG_DIR="${LOG_DIR:-${SCRIPT_DIR}/dist/oauth2-suite-logs}"

ALL_TASKS=("oauth2-feature-dev" "oauth2-ut-gen" "oauth2-refactor" "oauth2-perf")
DRY_RUN=false
SELECTED=()

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        oauth2-*)  SELECTED+=("$arg") ;;
        feature-dev|ut-gen|refactor|perf) SELECTED+=("oauth2-$arg") ;;
        -h|--help)
            sed -n '2,20p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) echo "[ERROR] 未知参数: $arg"; exit 1 ;;
    esac
done

[ ${#SELECTED[@]} -eq 0 ] && SELECTED=("${ALL_TASKS[@]}")

mkdir -p "${LOG_DIR}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

assemble_one() {
    local name="$1"
    log "组装 ${name}"
    bash "${SCRIPT_DIR}/assemble.sh" "${SCRIPT_DIR}/tasks/${name}/job.yml"
}

deploy_one() {
    local name="$1"
    local yaml="${SCRIPT_DIR}/dist/${name}.yml"
    [ -f "$yaml" ] || { echo "[ERROR] dist YAML 不存在: $yaml"; exit 1; }

    log "部署 ${name}"
    kubectl apply -f "$yaml"

    log "等待 ${name} 完成（最多 60 分钟）"
    if kubectl -n "${NAMESPACE}" wait --for=condition=Complete --timeout=3600s "job/${name}"; then
        log "${name} ✅ Complete"
    else
        log "${name} ⚠️ 未在 1 小时内完成 / Failed，继续收集日志"
    fi

    log "导出 ${name} Pod 日志 → ${LOG_DIR}/${name}.log"
    local pod
    pod=$(kubectl -n "${NAMESPACE}" get pod -l "job-name=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$pod" ]; then
        kubectl -n "${NAMESPACE}" logs "$pod" > "${LOG_DIR}/${name}.log" 2>&1 || true
    fi

    log "清理 ${name} (Job + ConfigMap)"
    kubectl delete -f "$yaml" --ignore-not-found
}

for task in "${SELECTED[@]}"; do
    assemble_one "$task"
done

if $DRY_RUN; then
    log "✅ Dry-run 完成，dist/ 下已生成 ${#SELECTED[@]} 份 YAML，未部署。"
    exit 0
fi

for task in "${SELECTED[@]}"; do
    deploy_one "$task"
done

log "🎉 全部任务完成。日志在: ${LOG_DIR}"
ls -la "${LOG_DIR}"
