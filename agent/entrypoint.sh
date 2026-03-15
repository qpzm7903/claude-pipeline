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
log_success "克隆完成"

# ── stream-json 格式化脚本 ──────────────────────────────────────────

cat > /tmp/fmt_stream.py << 'PYEOF'
import sys, json

TEXT_LIMIT    = 500
CONTENT_LINES = 30

def p(s):
    print(s, flush=True)

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        obj = json.loads(raw)
    except ValueError:
        p(raw)
        continue

    t = obj.get('type', '')

    if t == 'system':
        if obj.get('subtype') == 'init':
            p('  [session] model=' + str(obj.get('model','')) + '  cwd=' + str(obj.get('cwd','')))
        continue

    if t == 'assistant':
        for block in obj.get('message', {}).get('content', []):
            bt = block.get('type', '')
            if bt == 'text':
                text = block.get('text', '').strip()
                if not text:
                    continue
                if len(text) > TEXT_LIMIT:
                    text = text[:TEXT_LIMIT] + ' ...'
                for ln in text.splitlines():
                    if ln.strip():
                        p('  * ' + ln)
            elif bt == 'tool_use':
                name = block.get('name', '')
                inp  = block.get('input', {})
                if name == 'Bash':
                    cmd = inp.get('command', '').replace('\n', '; ')[:160]
                    p('  > Bash    ' + cmd)
                elif name == 'Read':
                    fp     = inp.get('file_path', '')
                    offset = inp.get('offset', '')
                    lim    = inp.get('limit', '')
                    rng    = ('  L' + str(offset) + '+' + str(lim)) if offset else ''
                    p('  > Read    ' + fp + rng)
                elif name == 'Write':
                    p('  > Write   ' + inp.get('file_path', ''))
                elif name == 'Edit':
                    p('  > Edit    ' + inp.get('file_path', ''))
                elif name == 'Glob':
                    p('  > Glob    ' + inp.get('pattern', ''))
                elif name == 'Grep':
                    p('  > Grep    ' + inp.get('pattern', '') + '  @ ' + inp.get('path', '.'))
                elif name == 'TodoWrite':
                    p('  > Todo    ' + str(len(inp.get('todos', []))) + ' tasks')
                else:
                    p('  > ' + name)
        continue

    tr = obj.get('tool_use_result') or (obj if t == 'tool_result' else None)
    if tr is not None:
        if isinstance(tr, dict):
            stdout  = tr.get('stdout', '')
            stderr  = tr.get('stderr', '')
            content = tr.get('content', '')
            if stdout:
                for ln in stdout.rstrip().splitlines():
                    p('  | ' + ln)
            if stderr and str(tr.get('exitCode', '0')) != '0':
                for ln in stderr.rstrip().splitlines()[:5]:
                    p('  ! ' + ln)
            if content and not stdout:
                lines = content.splitlines()
                for ln in lines[:CONTENT_LINES]:
                    p('  | ' + ln)
                if len(lines) > CONTENT_LINES:
                    p('  | ... (' + str(len(lines) - CONTENT_LINES) + ' more lines)')
            parts = []
            for k in ('numLines', 'totalLines', 'numFiles', 'durationMs', 'truncated', 'exitCode'):
                if k in tr:
                    parts.append(k + '=' + str(tr[k]))
            if parts:
                p('  < ' + ', '.join(parts))
        elif isinstance(tr, list):
            for item in tr[:3]:
                p('  | ' + str(item)[:120])
            if len(tr) > 3:
                p('  | ... (' + str(len(tr) - 3) + ' more)')
        else:
            text = str(tr).strip()
            if text:
                for ln in text.splitlines()[:10]:
                    p('  | ' + ln)
        continue

    if 'content' in obj or 'tool_use_result' in obj:
        file_obj = obj.get('file') or {}
        content  = obj.get('content', '')
        if isinstance(content, str) and content.strip():
            lines = content.splitlines()
            for ln in lines[:CONTENT_LINES]:
                p('  | ' + ln)
            if len(lines) > CONTENT_LINES:
                p('  | ... (' + str(len(lines) - CONTENT_LINES) + ' more lines)')
        elif file_obj:
            fp  = file_obj.get('filePath', '')
            nln = file_obj.get('numLines', '?')
            p('  < file: ' + fp + '  (' + str(nln) + ' lines)')
        continue

    if t == 'result':
        cost     = obj.get('cost_usd', 0) or 0
        turns    = obj.get('num_turns', 0)
        duration = (obj.get('duration_ms', 0) or 0) // 1000
        subtype  = obj.get('subtype', '')
        p('  [done] ' + subtype + '  turns=' + str(turns) + '  cost=$' + '{:.4f}'.format(cost) + '  ' + str(duration) + 's')
        continue
PYEOF

_fmt_stream() {
  python3 -u /tmp/fmt_stream.py 2>&1 | while IFS= read -r _fmtline; do
    echo "$_fmtline"
    echo "$_fmtline" >> "${_LOG_FILE:-/dev/null}" 2>/dev/null || true
  done
}

# ── 步骤 2: Claude 自主执行 ──────────────────────────────────────────

log_section "步骤 2: Claude 自主执行"

PROMPT="首先阅读项目的 CLAUDE.md 和 README.md 理解项目规范和当前状态。
如果项目使用 BMAD 工作流（存在 _bmad/ 目录或 .claude/skills/ 下有 bmad-* 文件夹），执行 bmad-help 分析当前状态。
分析完成后，请不要询问我，直接按照你的专业判断自动执行下一个必需的步骤（优先执行 bmad-create-story 准备新任务，或对 review 状态的任务执行 bmad-code-review）。
请持续工作，直到当前 Sprint 的逻辑链路闭环或遇到必须人工干预的阻塞性错误为止。

【工作流强制要求】
完成所有工作后，你必须自主完成以下收尾工作：
1. 运行测试进行自验证
2. 执行 git add -A && git commit（使用 Conventional Commits 格式）
3. 执行 git push 将代码推送到远程仓库
4. 如果你在一个新的分支上工作，且需要合并，请使用 gh pr create 命令自动创建 Pull Request

请注意，环境已预装 gh CLI 且已配置好相关的环境与权限，你可以直接使用。"

log_info "启动 Claude 自主执行..."

claude \
    --dangerously-skip-permissions \
    --print \
    --verbose \
    --output-format stream-json \
    <<< "${PROMPT}" 2>&1 | _fmt_stream
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_error "Claude 执行超时或失败"
    exit 2
fi

log_success "Claude 自主执行完成"
log_section "流水线完成 ✓"
log_info "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
exit 0
