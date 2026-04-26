#!/usr/bin/env bash
# run.sh - 小说创作 Multi-Agent 执行引擎
#
# 三个 Agent 角色串行协作:
#   1. Planner (剧情总编剧) — 读设定、推演大纲
#   2. Writer  (网文主笔)   — 按大纲写正文
#   3. Lore Master (设定管理员) — 归档记忆、更新设定

set -euo pipefail

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
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
ROUND_TIMEOUT="${ROUND_TIMEOUT:-3600}"
MODEL="${ANTHROPIC_MODEL:-claude-sonnet-4-6}"

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required}"
: "${REPO_URL:?REPO_URL is required}"

mkdir -pv "${WORKSPACE}" "${LOGS_DIR}"

# ── Git 配置 ────────────────────────────────────────────────────────
log_section "步骤 0: 环境准备"

git config --global user.name "${GIT_AUTHOR_NAME:-novel-bot}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-noreply@novel-bot.com}"

_GIT_TOKEN="${GIT_TOKEN:-${GH_TOKEN:-}}"
if [ -n "${_GIT_TOKEN}" ]; then
    if command -v gh &>/dev/null; then
        echo "${_GIT_TOKEN}" | gh auth login --with-token 2>/dev/null || true
    fi
    git config --global credential.helper 'store'
    _REPO_HOST=$(echo "${REPO_URL}" | sed -E 's|https?://([^/]+).*|\1|')
    echo "https://x-access-token:${_GIT_TOKEN}@${_REPO_HOST}" > ~/.git-credentials 2>/dev/null || true
fi

log_info "Claude: $(${CLAUDE_CMD} --version 2>/dev/null || echo 'unknown')"

# ── 仓库克隆 ────────────────────────────────────────────────────────
log_section "步骤 1: 仓库同步"

_retries=10
for i in $(seq 1 ${_retries}); do
    if [ ! -d "${WORKSPACE}/.git" ]; then
        rm -rf "${WORKSPACE}"
        mkdir -p "$(dirname "${WORKSPACE}")"
        git clone "${REPO_URL}" "${WORKSPACE}" 2>&1 && break
    else
        (cd "${WORKSPACE}" && git fetch --all --prune 2>&1) && break
    fi
    log_warning "Git sync failed, retry ${i}/${_retries}"
    sleep 3
done
[ -d "${WORKSPACE}/.git" ] || { log_error "Repository not available"; exit 11; }

cd "${WORKSPACE}"
[ -f "/pipeline/prompt.md" ] && cp /pipeline/prompt.md "${WORKSPACE}/prompt.md"

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
    fi
    log_info "[${step_name}] Finished (exit=${_exit})"
    return 0
}

# ── 步骤 2: Multi-Agent 小说创作 ───────────────────────────────────
log_section "步骤 2: Multi-Agent 创作"

echo "=== [Agent 1] 剧情总编剧 (Planner) ==="
_run_claude "planner" "${PLANNER_MODEL:-${MODEL}}" \
    "工作目录为: ${WORKSPACE}。你是【剧情总编剧】Agent。请先调用文件读取工具读取 story_summary.md、world_setting.md 以及最近的几章正文。然后结合 prompt.md 中的总体要求，在 plan.md 中深度推演并写下接下来 10 章的详细大纲（不要去写小说正文！）。" \
    "3600"

echo "=== [Agent 2] 网文主笔 (Writer) ==="
_run_claude "writer" "${WRITER_MODEL:-${MODEL}}" \
    "工作目录为: ${WORKSPACE}。你是【网文主笔】Agent。请读取 plan.md 中最新的大纲。严格按照大纲，结合 prompt.md 的文风要求，一章一章地编写接下来的 10 章正文并保存到 chapters/ 目录中。你的任务仅限写正文，写完即止。" \
    "${ROUND_TIMEOUT}"

echo "=== [Agent 3] 设定管理员 (Lore Master) ==="
_run_claude "loremaster" "${LOREMASTER_MODEL:-${MODEL}}" \
    "工作目录为: ${WORKSPACE}。你是【设定管理员】Agent。请阅读刚刚由主笔新写出的正文。将新剧情提炼追加到 story_summary.md 中，并把正文中新出现的人物、功法、地图更新到 world_setting.md 和 characters.md 中。" \
    "3600"

# ── 步骤 3: 结果归档 ──────────────────────────────────────────────
log_section "步骤 3: 结果归档"

cd "${WORKSPACE}"
git add -A 2>/dev/null || true
if ! git diff-index --quiet HEAD 2>/dev/null; then
    git commit -m "feat(novel): 新增 10 章内容" 2>/dev/null || true
fi
git push origin main 2>/dev/null || git push origin master 2>/dev/null || true

log_info "Logs:"
ls -la "${LOGS_DIR}/" 2>/dev/null || true

if [ -n "${ISC_SLEEP_TIME:-}" ]; then
    sleep "${ISC_SLEEP_TIME}s"
fi

log_section "Pipeline 完成 ✓"
