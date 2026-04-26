#!/usr/bin/env bash
# run-multi-agent.sh - Multi-Agent 执行引擎
#
# 与 run.sh 相同的基础设施（仓库克隆、Git 配置、日志），
# 但支持在 run.sh 内串行调用多个 agent 角色。
#
# 适用场景: 小说创作（Planner → Writer → Lore Master）、
#           单测生成（Planner → Writer → Reviewer）等

set -euo pipefail

# ── 日志工具 ────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()    { echo "[$(_ts)] [INFO]  $*"; }
log_warning() { echo "[$(_ts)] [WARN]  $*"; }
log_error()   { echo "[$(_ts)] [ERROR] $*"; }
log_section() { echo ""; echo "═══════════════════════════════════════════"; echo "  $*"; echo "═══════════════════════════════════════════"; }

_fmt_stream() {
    if [ -f "/agent/lib/fmt_stream.py" ]; then
        python3 -u "/agent/lib/fmt_stream.py"
    else
        cat
    fi
}

# ── 环境变量 ────────────────────────────────────────────────────────
WORKSPACE="${WORKSPACE:-/workspace/data}"
LOGS_DIR="${LOGS_DIR:-/workspace/logs}"
PROMPT_FILE="${PROMPT_FILE:-/pipeline/prompt.md}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
ROUND_TIMEOUT="${ROUND_TIMEOUT:-3600}"
MODEL="${ANTHROPIC_MODEL:-claude-sonnet-4-6}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-claude-pipeline}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-noreply@claude.local}"

# ── 步骤 0: 环境检查 ──────────────────────────────────────────────
log_section "步骤 0: 环境检查"

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required}"
: "${REPO_URL:?REPO_URL is required}"

if ! command -v "${CLAUDE_CMD}" &>/dev/null; then
    log_error "Claude CLI not found: ${CLAUDE_CMD}"
    exit 1
fi

log_info "Repo:     ${REPO_URL}"
log_info "Model:    ${MODEL}"
log_info "Base URL: ${ANTHROPIC_BASE_URL:-(official)}"
log_info "Timeout:  ${ROUND_TIMEOUT}s"
log_info "Claude:   $(${CLAUDE_CMD} --version 2>/dev/null || echo 'unknown')"

mkdir -pv "${WORKSPACE}" "${LOGS_DIR}"

# ── Git 配置 ────────────────────────────────────────────────────────
git config --global user.name "${GIT_AUTHOR_NAME}"
git config --global user.email "${GIT_AUTHOR_EMAIL}"

_GIT_TOKEN="${GIT_TOKEN:-${GH_TOKEN:-}}"
if [ -n "${_GIT_TOKEN}" ]; then
    if command -v gh &>/dev/null; then
        echo "${_GIT_TOKEN}" | gh auth login --with-token 2>/dev/null || true
    fi
    git config --global credential.helper 'store'
    _REPO_HOST=$(echo "${REPO_URL}" | sed -E 's|https?://([^/]+).*|\1|')
    echo "https://x-access-token:${_GIT_TOKEN}@${_REPO_HOST}" > ~/.git-credentials 2>/dev/null || true
fi

# ── 步骤 1: 仓库克隆 ──────────────────────────────────────────────
log_section "步骤 1: 仓库同步"

_clone_retries=10
_clone_ok=false
for i in $(seq 1 ${_clone_retries}); do
    if [ ! -d "${WORKSPACE}/.git" ]; then
        rm -rf "${WORKSPACE}"
        mkdir -p "$(dirname "${WORKSPACE}")"
        if git clone "${REPO_URL}" "${WORKSPACE}" 2>&1; then
            _clone_ok=true
            break
        fi
    else
        if (cd "${WORKSPACE}" && git fetch --all --prune 2>&1); then
            _clone_ok=true
            break
        fi
    fi
    log_warning "Git clone/fetch failed, retry ${i}/${_clone_retries}"
    sleep 3
done

[ "${_clone_ok}" = "true" ] || { log_error "Repository not available"; exit 11; }

cd "${WORKSPACE}"

# 复制 prompt.md 到工作目录
[ -f "${PROMPT_FILE}" ] && cp "${PROMPT_FILE}" "${WORKSPACE}/prompt.md"

log_info "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
log_info "HEAD:   $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

# ── Claude 执行工具 ─────────────────────────────────────────────────
_run_claude() {
    local step_name="$1"
    local model="$2"
    local prompt="$3"
    local step_timeout="${4:-${ROUND_TIMEOUT}}"

    log_info "[${step_name}] Starting (model=${model}, timeout=${step_timeout}s)"

    local _exit=0
    timeout "${step_timeout}" \
        "${CLAUDE_CMD}" \
            --dangerously-skip-permissions \
            --print \
            --verbose \
            --output-format stream-json \
            --model "${model}" \
            -p "${prompt}" \
        2>&1 | tee "${LOGS_DIR}/${step_name}_result.txt" | _fmt_stream | tee "${LOGS_DIR}/${step_name}_pretty.txt" || _exit=$?

    if [ "${PIPESTATUS[0]:-${_exit}}" -eq 124 ]; then
        log_warning "[${step_name}] Timed out"
    elif [ "${_exit}" -ne 0 ]; then
        log_warning "[${step_name}] Exited with code ${_exit}"
    else
        log_info "[${step_name}] Completed"
    fi

    return 0  # 不因单个 agent 失败中断整个流水线
}

# ── 步骤 2: Multi-Agent 执行 ────────────────────────────────────────
log_section "步骤 2: Multi-Agent 执行"

# ==================================================================
# 在下面定义你的 agent 调用序列
# 格式: _run_claude "步骤名" "模型" "prompt" [超时秒数]
#
# 如果某些任务需要不同模型，可以直接换模型名:
#   _run_claude "planner" "glm-5.1"    "..."
#   _run_claude "writer"  "kimi-k2.6"  "..."
# ==================================================================

echo "=== [Agent 1] 规划者 (Planner) ==="
_run_claude "planner" "${PLANNER_MODEL:-${MODEL}}" \
    "工作目录为: ${WORKSPACE}。你是【任务规划者】。请先读取 prompt.md 的要求，分析代码仓库结构，制定详细的执行计划并写入 plan.md。不要执行实际的代码修改工作。"

echo "=== [Agent 2] 执行者 (Worker) ==="
_run_claude "worker" "${WORKER_MODEL:-${MODEL}}" \
    "工作目录为: ${WORKSPACE}。你是【主执行者】。请读取 plan.md 中的计划，然后严格按照 prompt.md 的要求执行实际工作。完成后提交代码。" \
    "${ROUND_TIMEOUT}"

# ── 步骤 3: 结果归档 ──────────────────────────────────────────────
log_section "步骤 3: 结果归档"

cd "${WORKSPACE}"
git add -A 2>/dev/null || true
if ! git diff-index --quiet HEAD 2>/dev/null; then
    git commit -m "chore: agent auto-commit remaining changes" 2>/dev/null || true
fi
git push 2>/dev/null || git push origin main 2>/dev/null || git push origin master 2>/dev/null || true

log_info "Logs:"
ls -la "${LOGS_DIR}/" 2>/dev/null || true

if [ -n "${ISC_SLEEP_TIME:-}" ]; then
    log_info "Sleeping ${ISC_SLEEP_TIME}s"
    sleep "${ISC_SLEEP_TIME}s"
fi

log_section "Pipeline 完成 ✓"
