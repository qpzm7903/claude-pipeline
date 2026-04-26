#!/usr/bin/env bash
# run.sh - Claude Pipeline Job 通用执行引擎
#
# 职责: 仓库克隆 → Claude 执行 → 结果归档 → Git 推送
# 依赖: claude CLI, git, python3 (可选: gh, jq)
# 输入: 环境变量 + /pipeline/prompt.md
# 输出: /workspace/logs/ 下的执行日志
#
# 支持三种执行模式 (EXEC_MODE):
#   single      — 单次执行（默认）
#   iterate     — 多轮迭代，直到收敛或达到上限
#   multi-agent — 在 run.sh 中串行调用多个 agent 角色（需自定义 run.sh）

set -euo pipefail

# ── 日志工具 ────────────────────────────────────────────────────────
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()    { echo "[$(_ts)] [INFO]  $*"; }
log_warning() { echo "[$(_ts)] [WARN]  $*"; }
log_error()   { echo "[$(_ts)] [ERROR] $*"; }
log_section() { echo ""; echo "═══════════════════════════════════════════"; echo "  $*"; echo "═══════════════════════════════════════════"; }

# ── 格式化输出 ──────────────────────────────────────────────────────
_fmt_stream() {
    if [ -f "/agent/lib/fmt_stream.py" ]; then
        python3 -u "/agent/lib/fmt_stream.py"
    else
        cat
    fi
}

# ── 环境变量（带默认值）────────────────────────────────────────────
WORKSPACE="${WORKSPACE:-/workspace/data}"
LOGS_DIR="${LOGS_DIR:-/workspace/logs}"
PROMPT_FILE="${PROMPT_FILE:-/pipeline/prompt.md}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
ROUND_TIMEOUT="${ROUND_TIMEOUT:-3600}"
EXEC_MODE="${EXEC_MODE:-single}"
MAX_ITERATIONS="${MAX_ITERATIONS:-1}"
ITER_COOLDOWN="${ITER_COOLDOWN:-15}"
MAX_NOCHANGE="${MAX_NOCHANGE:-2}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-claude-pipeline}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-noreply@claude.local}"
MODEL="${ANTHROPIC_MODEL:-claude-sonnet-4-6}"

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
log_info "Mode:     ${EXEC_MODE}"
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

if [ "${_clone_ok}" != "true" ]; then
    log_error "Failed to clone repository after ${_clone_retries} retries"
    exit 11
fi

cd "${WORKSPACE}"

# 复制 prompt.md 到工作目录（如果存在挂载文件）
if [ -f "${PROMPT_FILE}" ]; then
    cp "${PROMPT_FILE}" "${WORKSPACE}/prompt.md"
    log_info "Prompt file → workspace/prompt.md"
fi

# ── Skills 同步（Claude Code 从 $CWD/.claude/skills/ 自动发现）──────
SKILLS_SRC="${SKILLS_SRC:-/skills}"
if [ -d "${SKILLS_SRC}" ] && [ "$(ls -A "${SKILLS_SRC}" 2>/dev/null)" ]; then
    mkdir -p "${WORKSPACE}/.claude/skills"
    cp -R "${SKILLS_SRC}/." "${WORKSPACE}/.claude/skills/"
    _skill_count=$(find "${WORKSPACE}/.claude/skills" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')
    log_info "Skills synced: ${_skill_count} skills → .claude/skills/"
    for _sd in "${WORKSPACE}/.claude/skills"/*/; do
        [ -f "${_sd}/SKILL.md" ] && log_info "  - $(basename "${_sd}")"
    done
    # 防止 Skills 被 git add -A 提交到目标仓库
    if ! grep -qF '.claude/skills/' "${WORKSPACE}/.gitignore" 2>/dev/null; then
        echo -e '\n# Pipeline-injected Skills (do not commit)\n.claude/skills/' >> "${WORKSPACE}/.gitignore"
        log_info "Added .claude/skills/ to .gitignore"
    fi
fi

# ── Settings.json 同步（确保 ~/.claude/settings.json 存在）──────────
CLAUDE_HOME="${HOME}/.claude"
if [ -f "${CLAUDE_HOME}/settings.json" ]; then
    log_info "Settings: ${CLAUDE_HOME}/settings.json (mounted)"
elif [ -f "/pipeline/settings.json" ]; then
    mkdir -p "${CLAUDE_HOME}"
    cp "/pipeline/settings.json" "${CLAUDE_HOME}/settings.json"
    log_info "Settings: copied from /pipeline/settings.json"
fi

log_info "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
log_info "HEAD:   $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

BEFORE_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")

# ── Claude 执行工具 ─────────────────────────────────────────────────
_run_claude() {
    local prompt="$1"
    local model="${2:-${MODEL}}"
    local step_name="${3:-main}"
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
        log_warning "[${step_name}] Timed out (${step_timeout}s)"
    elif [ "${_exit}" -ne 0 ]; then
        log_warning "[${step_name}] Exited with code ${_exit}"
    else
        log_info "[${step_name}] Completed"
    fi

    return "${_exit}"
}

# ── 步骤 2: Claude 自主执行 ─────────────────────────────────────────
log_section "步骤 2: Claude 自主执行"

# 构建 Prompt
if [ -n "${CLAUDE_PROMPT:-}" ]; then
    _PROMPT="${CLAUDE_PROMPT}"
    log_info "Prompt source: CLAUDE_PROMPT env (${#_PROMPT} chars)"
elif [ -f "${WORKSPACE}/prompt.md" ]; then
    _PROMPT="工作目录为: ${WORKSPACE} , 请严格按照当前目录下的 prompt.md 文件要求执行任务。"
    log_info "Prompt source: prompt.md file"
else
    log_error "No prompt provided. Set CLAUDE_PROMPT env or mount prompt.md"
    exit 12
fi

case "${EXEC_MODE}" in
    single)
        log_info "Mode: single (one-shot)"
        _run_claude "${_PROMPT}" "${MODEL}" "main" "${ROUND_TIMEOUT}" || true
        ;;

    iterate)
        log_info "Mode: iterate (max=${MAX_ITERATIONS}, cooldown=${ITER_COOLDOWN}s, max_nochange=${MAX_NOCHANGE})"
        _iter=0
        _consecutive_nochange=0
        _consecutive_fails=0

        while true; do
            _iter=$((_iter + 1))
            log_section "自主迭代 #${_iter}"

            _before=$(git rev-parse HEAD 2>/dev/null || echo "")
            git pull --rebase 2>/dev/null || true

            _exit=0
            _run_claude "${_PROMPT}" "${MODEL}" "iter-${_iter}" "${ROUND_TIMEOUT}" || _exit=$?

            _after=$(git rev-parse HEAD 2>/dev/null || echo "")

            if [ "${_before}" != "${_after}" ]; then
                log_info "Iteration #${_iter}: new commits"
                git push 2>/dev/null || log_warning "Push failed"
                _consecutive_fails=0
                _consecutive_nochange=0
            elif [ "${_exit}" -ne 0 ] && [ "${_exit}" -ne 124 ]; then
                _consecutive_fails=$((_consecutive_fails + 1))
                log_warning "Iteration #${_iter}: failed (code=${_exit}, consecutive=${_consecutive_fails})"
            else
                _consecutive_nochange=$((_consecutive_nochange + 1))
                log_info "Iteration #${_iter}: no changes (${_consecutive_nochange}/${MAX_NOCHANGE})"
                _consecutive_fails=0
            fi

            [ "${_consecutive_fails}" -ge 5 ] && { log_error "5 consecutive failures"; exit 2; }
            [ "${_consecutive_nochange}" -ge "${MAX_NOCHANGE}" ] && { log_info "Converged"; break; }
            [ "${MAX_ITERATIONS}" -gt 0 ] && [ "${_iter}" -ge "${MAX_ITERATIONS}" ] && { log_info "Max iterations reached"; break; }

            sleep "${ITER_COOLDOWN}"
        done
        ;;

    *)
        log_error "Unknown EXEC_MODE: ${EXEC_MODE} (options: single, iterate)"
        exit 1
        ;;
esac

# ── 步骤 3: 结果归档 ──────────────────────────────────────────────
log_section "步骤 3: 结果归档"

cd "${WORKSPACE}"
git add -A 2>/dev/null || true
if ! git diff-index --quiet HEAD 2>/dev/null; then
    git commit -m "chore: agent auto-commit remaining changes" 2>/dev/null || true
fi
git push 2>/dev/null || git push origin main 2>/dev/null || git push origin master 2>/dev/null || true

AFTER_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
log_info "Before: ${BEFORE_COMMIT:-none}"
log_info "After:  ${AFTER_COMMIT:-none}"
log_info "Logs:"
ls -la "${LOGS_DIR}/" 2>/dev/null || true

if [ -n "${ISC_SLEEP_TIME:-}" ]; then
    log_info "Sleeping ${ISC_SLEEP_TIME}s before exit"
    sleep "${ISC_SLEEP_TIME}s"
fi

log_section "Pipeline 完成 ✓"
