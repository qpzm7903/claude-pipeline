#!/usr/bin/env bash
# entrypoint.sh - Claude Pipeline Agent (极简版)
#
# bash 只做三件事：
#   1. 克隆仓库
#   2. 启动 Claude（自主决策一切）
#   3. 兜底提交 + 推送
#
# 所有决策逻辑（做什么、怎么做、何时提交）全部交给 Claude，
# 通过目标仓库的 CLAUDE.md 约束行为。

set -euo pipefail

# ── 环境配置 ────────────────────────────────────────────────────────
export ENABLE_LSP_TOOL=1

# ── 日志持久化：双写到 cargo-cache PVC ──────────────────────────────
_LOG_DIR="/home/pipeline/.cargo/registry/pipeline-logs"
_LOG_FILE="/dev/null"
mkdir -p "${_LOG_DIR}" 2>/dev/null || true
if [ -d "${_LOG_DIR}" ] && [ -w "${_LOG_DIR}" ]; then
  _LOG_FILE="${_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-$(hostname -s 2>/dev/null || echo pod).log"
  find "${_LOG_DIR}" -name "*.log" -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | head -n -30 | awk '{print $2}' | xargs rm -f 2>/dev/null || true
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*";   echo "[INFO]    $*" >> "${_LOG_FILE}"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*";  echo "[OK]      $*" >> "${_LOG_FILE}"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC}  $*"; echo "[WARN]    $*" >> "${_LOG_FILE}"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*";   echo "[ERROR]   $*" >> "${_LOG_FILE}"; }
log_section() { echo -e "\n${BLUE}════════════════════════════════════════\n  $*\n════════════════════════════════════════${NC}\n"; echo -e "\n=== $* ===" >> "${_LOG_FILE}"; }

WORKSPACE="/workspace"

log_section "Claude Pipeline Agent 启动"
log_info "Repo:     ${REPO_URL}"
log_info "Model:    ${ANTHROPIC_MODEL:-(default)}"
log_info "Base URL: ${ANTHROPIC_BASE_URL:-(official)}"

# ── 步骤 0: 环境检查 ────────────────────────────────────────────────

log_section "步骤 0: 环境检查"

[ -z "${ANTHROPIC_API_KEY:-}" ] && { log_error "ANTHROPIC_API_KEY 未设置"; exit 1; }
[ -z "${REPO_URL:-}" ]          && { log_error "REPO_URL 未设置"; exit 1; }
command -v claude &>/dev/null   || { log_error "claude CLI 未安装"; exit 1; }

log_success "环境检查通过"

# ── 步骤 1: 克隆仓库 ────────────────────────────────────────────────

log_section "步骤 1: 克隆仓库"

AUTH_URL="${REPO_URL}"
[ -n "${GIT_TOKEN:-}" ] && AUTH_URL="${REPO_URL/https:\/\//https://x-access-token:${GIT_TOKEN}@}"

CLONE_OK=false
for _clone_attempt in 1 2 3; do
  if git clone --depth=20 "${AUTH_URL}" "${WORKSPACE}" 2>&1; then
    CLONE_OK=true; break
  fi
  log_warning "克隆失败（attempt ${_clone_attempt}/3），${_clone_attempt}0s 后重试..."
  sleep $((_clone_attempt * 10))
done
[ "$CLONE_OK" = "false" ] && { log_error "克隆仓库失败（3次重试后）"; exit 1; }

cd "${WORKSPACE}"
git config user.name  "${GIT_AUTHOR_NAME:-Claude Pipeline Bot}"
git config user.email "${GIT_AUTHOR_EMAIL:-pipeline@claude.ai}"

BEFORE_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
log_success "克隆完成"

# ── Rust 编译缓存（增量编译） ─────────────────────────────────────
_BUILD_CACHE="/home/pipeline/.build-cache"
if [ -d "${_BUILD_CACHE}" ] && [ -w "${_BUILD_CACHE}" ]; then
  _REPO_SLUG=$(echo "${REPO_URL}" | sed -E 's|.*github\.com[/:]||; s|\.git$||; s|/|-|g' | tr '[:upper:]' '[:lower:]')
  export CARGO_TARGET_DIR="${_BUILD_CACHE}/${_REPO_SLUG}"
  mkdir -p "${CARGO_TARGET_DIR}" 2>/dev/null || true
  # 清理 7 天未使用的缓存（其他 repo 的旧缓存）
  find "${_BUILD_CACHE}" -maxdepth 1 -mindepth 1 -type d -not -name "${_REPO_SLUG}" \
    -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
  log_info "Build cache: ${CARGO_TARGET_DIR}"
fi

# ── stream-json 格式化脚本 ──────────────────────────────────────────

cat > /tmp/fmt_stream.py << 'PYEOF'
import sys, json

TEXT_LIMIT    = 500
CONTENT_LINES = 15

# Colors for terminal output
C_THOUGHT = '\033[38;5;245m'  # Dim gray for thoughts
C_ACTION  = '\033[1;36m'      # Cyan for actions
C_RESULT  = '\033[0;32m'      # Green for results
C_INFO    = '\033[1;34m'      # Blue for info
C_RESET   = '\033[0m'
C_DIM     = '\033[2m'         # Dim filter for results

def p(s, end='\n'):
    print(s, end=end, flush=True)

def process(obj):
    t = obj.get('type', '')

    if t == 'system' and obj.get('subtype') == 'init':
        p(f"\n{C_INFO}🚀 [Init] model={obj.get('model','')} cwd={obj.get('cwd','')}{C_RESET}")
        return

    if t == 'assistant':
        content = obj.get('message', {}).get('content', [])
        has_thought = False
        for block in content:
            bt = block.get('type', '')
            if bt == 'text':
                text = block.get('text', '').strip()
                if not text: continue
                if len(text) > TEXT_LIMIT: text = text[:TEXT_LIMIT] + ' ... (truncated)'
                if not has_thought:
                    p(f"\n{C_THOUGHT}🧠 [Thought]{C_RESET}")
                    has_thought = True
                for ln in text.splitlines():
                    if ln.strip(): p(f"{C_THOUGHT}    {ln}{C_RESET}")
            elif bt == 'tool_use':
                name = block.get('name', '')
                inp  = block.get('input', {})
                p(f"{C_ACTION}🛠️  [{name}]{C_RESET} ", end="")
                if name == 'Bash':
                    cmd = inp.get('command', '').replace('\n', '; ')[:120]
                    p(f"$ {cmd}")
                elif name == 'Read':
                    fp = inp.get('file_path', '')
                    rng = f" L{inp.get('offset', '')}+{inp.get('limit', '')}" if inp.get('offset') else ""
                    p(f"📄 {fp}{rng}")
                elif name == 'Write' or name == 'Edit':
                    p(f"📝 {inp.get('file_path', '')}")
                elif name == 'Glob':
                    p(f"🔍 {inp.get('pattern', '')}")
                elif name == 'Grep':
                    p(f"🔎 {inp.get('pattern', '')} @ {inp.get('path', '.')}")
                elif name in ('TodoWrite', 'TodoRead'):
                    p(f"📋 {len(inp.get('todos', []))} tasks")
                else:
                    p(f"▶ {str(inp)[:80]}")
        return

    tr = obj.get('tool_use_result') or (obj if t == 'tool_result' else None)
    if tr is not None:
        has_content = False
        parts = []
        is_err = False
        if isinstance(tr, dict):
            stdout = tr.get('stdout', '')
            stderr = tr.get('stderr', '')
            content = tr.get('content', '')
            if str(tr.get('exitCode', '0')) != '0' and stderr:
                is_err = True
            for k in ('numLines', 'totalLines', 'numFiles', 'exitCode'):
                if k in tr: parts.append(f"{k}={tr[k]}")
            if stdout or stderr or content:
                has_content = True
        elif isinstance(tr, list) and tr:
            has_content = True
        else:
            if str(tr).strip(): has_content = True

        icon = '❌' if is_err else '✅'
        color = '\033[0;31m' if is_err else C_RESULT

        if not has_content and not parts:
            p(f"{color}    {icon} [Success]{C_RESET}")
            return

        p(f"{color}    {icon} [Result]{C_RESET}")

        if isinstance(tr, dict):
            if stdout:
                lines = stdout.rstrip().splitlines()
                for ln in lines[:CONTENT_LINES]:
                    p(f"{C_DIM}      | {ln.strip()[:150]}{C_RESET}")
                if len(lines) > CONTENT_LINES:
                    p(f"{C_DIM}      | ... ({len(lines) - CONTENT_LINES} more lines){C_RESET}")
            if stderr and is_err:
                for ln in stderr.rstrip().splitlines()[:10]:
                    p(f"{C_DIM}      ! {ln.strip()[:150]}{C_RESET}")
            if content and not stdout:
                if isinstance(content, list):
                    lines = [str(item)[:150] for item in content]
                elif isinstance(content, str):
                    lines = content.splitlines()
                else:
                    lines = [str(content)]
                for ln in lines[:CONTENT_LINES]:
                    p(f"{C_DIM}      | {ln.strip()[:150]}{C_RESET}")
                if len(lines) > CONTENT_LINES:
                    p(f"{C_DIM}      | ... ({len(lines) - CONTENT_LINES} more lines){C_RESET}")
            if parts:
                p(f"{C_DIM}      └─ {', '.join(parts)}{C_RESET}")
        elif isinstance(tr, list):
            for item in tr[:3]:
                p(f"{C_DIM}      | {str(item)[:120]}{C_RESET}")
        else:
            text = str(tr).strip()
            if text:
                for ln in text.splitlines()[:5]:
                    p(f"{C_DIM}      | {ln.strip()[:150]}{C_RESET}")
        return

    if 'content' in obj or 'tool_use_result' in obj:
        file_obj = obj.get('file') or {}
        content  = obj.get('content', '')
        if isinstance(content, str) and content.strip():
            lines = content.splitlines()
            for ln in lines[:CONTENT_LINES]:
                p(f"{C_DIM}      | {ln.strip()[:150]}{C_RESET}")
            if len(lines) > CONTENT_LINES:
                p(f"{C_DIM}      | ... ({len(lines) - CONTENT_LINES} more lines){C_RESET}")
        elif file_obj:
            fp  = file_obj.get('filePath', '')
            nln = file_obj.get('numLines', '?')
            p(f"{C_DIM}      < file: {fp}  ({nln} lines){C_RESET}")
        return

    if t == 'result':
        cost = obj.get('cost_usd', 0) or 0
        turns = obj.get('num_turns', 0)
        p(f"\n{C_INFO}🏁 [结束 DONE] turns={turns} cost=${cost:.4f}{C_RESET}")

for raw in sys.stdin:
    raw = raw.strip()
    if not raw: continue
    try:
        obj = json.loads(raw)
    except ValueError:
        continue
    try:
        process(obj)
    except Exception:
        pass
PYEOF

_fmt_stream() {
  python3 -u /tmp/fmt_stream.py 2>&1 | while IFS= read -r _fmtline; do
    echo "$_fmtline"
    echo "$_fmtline" >> "${_LOG_FILE:-/dev/null}" 2>/dev/null || true
  done
}

# ── 步骤 2: Claude 自主执行 ──────────────────────────────────────────

log_section "步骤 2: Claude 自主执行"

# ── Prompt 三级加载（优先级从高到低） ────────────────────────────────
#
#  1. CLAUDE_PROMPT_FILE — 文件路径（Docker -v 挂载 / K8s ConfigMap volumeMount）
#     例: -e CLAUDE_PROMPT_FILE=/prompts/my-prompt.txt
#         -v /host/my-prompt.txt:/prompts/my-prompt.txt:ro
#
#  2. CLAUDE_PROMPT — 内联字符串（Docker -e / K8s env valueFrom ConfigMapKeyRef）
#     例: -e CLAUDE_PROMPT="$(cat custom-prompt.txt)"
#
#  3. /agent/default-prompt.txt — 镜像内置默认（无需任何配置）
#
if [ -n "${CLAUDE_PROMPT_FILE:-}" ]; then
  if [ -f "${CLAUDE_PROMPT_FILE}" ]; then
    PROMPT=$(cat "${CLAUDE_PROMPT_FILE}")
    log_info "Prompt 来源: 文件 ${CLAUDE_PROMPT_FILE}"
  else
    log_error "CLAUDE_PROMPT_FILE 指定的文件不存在: ${CLAUDE_PROMPT_FILE}"
    exit 1
  fi
elif [ -n "${CLAUDE_PROMPT:-}" ]; then
  PROMPT="${CLAUDE_PROMPT}"
  log_info "Prompt 来源: 环境变量 CLAUDE_PROMPT (${#PROMPT} 字符)"
elif [ -f "/agent/default-prompt.txt" ]; then
  PROMPT=$(cat /agent/default-prompt.txt)
  log_info "Prompt 来源: 镜像内置默认 /agent/default-prompt.txt"
else
  log_error "未找到可用 Prompt：请设置 CLAUDE_PROMPT_FILE、CLAUDE_PROMPT，或确保镜像含 /agent/default-prompt.txt"
  exit 1
fi

# ── 执行 Claude ───────────────────────────────────────────────────────
#
# AUTO_ITERATE=true  → autoresearch 模式：崩溃重启无限循环
# AUTO_ITERATE=false → 默认单次执行模式
#

_run_claude() {
  claude \
      --dangerously-skip-permissions \
      --print \
      --verbose \
      --output-format stream-json \
      <<< "${PROMPT}" 2>&1 | _fmt_stream
  return "${PIPESTATUS[0]}"
}

if [ "${AUTO_ITERATE:-false}" = "true" ]; then
  # ── autoresearch 模式：无限循环 + 崩溃重启 ───────────────────────
  _ITER=0
  _MAX_ITER="${MAX_ITERATIONS:-0}"       # 0 = 无限
  _COOLDOWN="${ITER_COOLDOWN:-10}"       # 迭代间隔秒
  _CONSECUTIVE_FAILS=0

  log_info "模式: AUTO_ITERATE (max=${_MAX_ITER:-∞}, cooldown=${_COOLDOWN}s)"

  while true; do
    _ITER=$((_ITER + 1))
    log_section "自主迭代 #${_ITER}"

    _BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "")

    _EXIT=0
    _run_claude || _EXIT=$?

    _AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")

    if [ "$_BEFORE" != "$_AFTER" ]; then
      log_success "迭代 #${_ITER}: 产生新 commit"
      git push 2>/dev/null || log_warning "push 失败，下轮重试"
      _CONSECUTIVE_FAILS=0
    elif [ $_EXIT -ne 0 ]; then
      _CONSECUTIVE_FAILS=$((_CONSECUTIVE_FAILS + 1))
      log_warning "迭代 #${_ITER}: Claude 异常退出 (code=$_EXIT, 连续失败=${_CONSECUTIVE_FAILS})"
      # 拉取远程最新代码（可能有其他 agent 的推送）
      git pull --rebase 2>/dev/null || true
    else
      log_info "迭代 #${_ITER}: 无变更（Claude 正常退出）"
      _CONSECUTIVE_FAILS=0
    fi

    # 连续失败 5 次，认为存在系统性问题，退出
    if [ $_CONSECUTIVE_FAILS -ge 5 ]; then
      log_error "连续 ${_CONSECUTIVE_FAILS} 次失败，退出"
      exit 2
    fi

    # 检查是否达到最大迭代次数
    if [ "$_MAX_ITER" -gt 0 ] && [ "$_ITER" -ge "$_MAX_ITER" ]; then
      log_info "达到最大迭代次数 $_MAX_ITER，退出"
      break
    fi

    sleep "$_COOLDOWN"
  done

else
  # ── 默认单次执行模式 ────────────────────────────────────────────
  log_info "启动 Claude 自主执行..."

  _EXIT=0
  _run_claude || _EXIT=$?
  if [ $_EXIT -ne 0 ]; then
      log_error "Claude 执行超时或失败"
      exit 2
  fi

  log_success "Claude 自主执行完成"

  AFTER_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$BEFORE_COMMIT" ] && [ "$BEFORE_COMMIT" = "$AFTER_COMMIT" ]; then
      log_error "Pipeline 失败: 代码仓库没有任何新的 commit (避免 Completed 状态虚假成功)"
      exit 3
  fi
fi

log_section "流水线完成 ✓"
log_info "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
exit 0
