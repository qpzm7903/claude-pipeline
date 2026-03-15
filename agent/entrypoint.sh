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

# ── stream-json 格式化脚本 ──────────────────────────────────────────

cat > /tmp/fmt_stream.py << 'PYEOF'
import sys, json

TEXT_LIMIT    = 1000
CONTENT_LINES = 50

# Colors for terminal output
C_THOUGHT = '\033[1;35m'
C_ACTION  = '\033[1;36m'
C_RESULT  = '\033[1;32m'
C_INFO    = '\033[1;34m'
C_RESET   = '\033[0m'

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
            p(f"{C_INFO}🚀 [初始化 Init] model={obj.get('model','')} cwd={obj.get('cwd','')}{C_RESET}")
        continue

    if t == 'assistant':
        for block in obj.get('message', {}).get('content', []):
            bt = block.get('type', '')
            if bt == 'text':
                text = block.get('text', '').strip()
                if not text:
                    continue
                if len(text) > TEXT_LIMIT:
                    text = text[:TEXT_LIMIT] + ' ... (truncated)'
                p(f"\n{C_THOUGHT}🧠 [思考 Thought]{C_RESET}")
                for ln in text.splitlines():
                    if ln.strip():
                        p('    ' + ln)
            elif bt == 'tool_use':
                name = block.get('name', '')
                inp  = block.get('input', {})
                p(f"\n{C_ACTION}🛠️  [行动 Action]: {name}{C_RESET}")
                if name == 'Bash':
                    cmd = inp.get('command', '').replace('\n', '; ')[:200]
                    p('    $ ' + cmd)
                elif name == 'Read':
                    fp     = inp.get('file_path', '')
                    offset = inp.get('offset', '')
                    lim    = inp.get('limit', '')
                    rng    = (' L' + str(offset) + '+' + str(lim)) if offset else ''
                    p('    📄 ' + fp + rng)
                elif name == 'Write':
                    p('    ✏️  ' + inp.get('file_path', ''))
                elif name == 'Edit':
                    p('    📝 ' + inp.get('file_path', ''))
                elif name == 'Glob':
                    p('    🔍 ' + inp.get('pattern', ''))
                elif name == 'Grep':
                    p('    🔎 ' + inp.get('pattern', '') + '  @ ' + inp.get('path', '.'))
                elif name in ('TodoWrite', 'TodoRead'):
                    p('    📋 ' + str(len(inp.get('todos', []))) + ' tasks')
                else:
                    p('    ▶ ' + str(inp)[:100])
        continue

    tr = obj.get('tool_use_result') or (obj if t == 'tool_result' else None)
    if tr is not None:
        p(f"{C_RESULT}✅ [结果 Result]{C_RESET}")
        if isinstance(tr, dict):
            stdout  = tr.get('stdout', '')
            stderr  = tr.get('stderr', '')
            content = tr.get('content', '')
            if stdout:
                lines = stdout.rstrip().splitlines()
                for ln in lines[:15]:
                    p('    | ' + ln)
                if len(lines) > 15:
                    p('    | ... (' + str(len(lines) - 15) + ' more lines)')
            if stderr and str(tr.get('exitCode', '0')) != '0':
                for ln in stderr.rstrip().splitlines()[:5]:
                    p('    ! ' + ln)
            if content and not stdout:
                lines = content.splitlines()
                for ln in lines[:CONTENT_LINES]:
                    p('    | ' + ln)
                if len(lines) > CONTENT_LINES:
                    p('    | ... (' + str(len(lines) - CONTENT_LINES) + ' more lines)')
            parts = []
            for k in ('numLines', 'totalLines', 'numFiles', 'durationMs', 'truncated', 'exitCode'):
                if k in tr:
                    parts.append(k + '=' + str(tr[k]))
            if parts:
                p('    └─ ' + ', '.join(parts))
        elif isinstance(tr, list):
            for item in tr[:3]:
                p('    | ' + str(item)[:120])
            if len(tr) > 3:
                p('    | ... (' + str(len(tr) - 3) + ' more)')
        else:
            text = str(tr).strip()
            if text:
                for ln in text.splitlines()[:10]:
                    p('    | ' + ln)
        continue

    if 'content' in obj or 'tool_use_result' in obj:
        file_obj = obj.get('file') or {}
        content  = obj.get('content', '')
        if isinstance(content, str) and content.strip():
            lines = content.splitlines()
            for ln in lines[:CONTENT_LINES]:
                p('    | ' + ln)
            if len(lines) > CONTENT_LINES:
                p('    | ... (' + str(len(lines) - CONTENT_LINES) + ' more lines)')
        elif file_obj:
            fp  = file_obj.get('filePath', '')
            nln = file_obj.get('numLines', '?')
            p('    < file: ' + fp + '  (' + str(nln) + ' lines)')
        continue

    if t == 'result':
        cost     = obj.get('cost_usd', 0) or 0
        turns    = obj.get('num_turns', 0)
        duration = (obj.get('duration_ms', 0) or 0) // 1000
        subtype  = obj.get('subtype', '')
        p(f"{C_INFO}🏁 [结束 DONE] {subtype} turns={turns} cost=${cost:.4f} {duration}s{C_RESET}")
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

如果项目使用 BMAD 工作流（存在 _bmad/ 目录或 .claude/skills/ 下有 bmad-* 文件夹），你**必须严格作为一个单步执行节点（状态机）**来工作，绝不允许在一个 session 内连续执行多个冗长的任务。

请分析当前项目状态，并**只执行当前最急需的唯一一个 BMAD 技能**。判断逻辑如下：
0. 启动时，**必须首先使用 gh CLI 检查最近一次 push 的 GitHub Actions/CI 执行状态**。如果最近的 CI 失败，必须优先进行修复；如果处于进行中，需等待执行完成；确认 CI 成功后才能继续其他全新任务。你可以自由决定使用哪些 gh 命令来完成状态检查与等待。
1. 如果还没规划完（没有架构或 Epic） -> 执行相关的规划技能（如 bmad-create-epics-and-stories）
2. 如果缺 sprint-status.yaml -> 执行 bmad-sprint-planning
3. 如果有待处理的 sprint，且当前不存在进行中的 story -> 执行 bmad-create-story 准备新任务
4. 如果有刚创建好、待开发的 story -> 执行 bmad-dev-story 进行开发
5. 如果开发刚刚完成、待审查 -> 执行 bmad-code-review
6. 如果一个 story 的 code-review 刚刚通过 -> **必须执行 bmad-retrospective 进行该 story 的复盘和经验总结**
7. 如果 epic 全部完成 -> 执行 bmad-retrospective 进行 epic 级别复盘

【极严格的单步执行要求】
- 你在本次会话中，**只允许执行上述清单中的 1 个核心 BMAD 技能**！
- 该技能执行完毕后，你必须立刻整理并保存输出文件，然后提交代码并结束本次会话！
- **绝对不要**在没有重新启动新 session 的情况下，接着做下一步骤！这会导致上下文爆炸。

【工作流强制要求】
在工作期间和收尾阶段，你必须自主完成以下动作：
1. 分阶段尽早提交：完成你本次负责的那个唯一独立任务后，立即执行 git add -A && git commit（使用 Conventional Commits 格式）。
2. 运行测试进行自验证（如果是 dev-story 等阶段）
3. 最终执行 git push 将所有代码推送到远程仓库。**Push 后，建议继续使用 gh CLI 监控并等待 Github Action 执行成功后再结束任务；或者 Push 后立刻结束，由下一个接手的容器启动时检查 CI 状态**。你可以自由决定使用哪些 gh 命令来进行监控。
4. 如果你在一个新的分支上工作，且需要合并，请使用 gh pr create 命令自动创建 Pull Request

【代码审查强制提交规则】（最高优先级，不可违反）
如果你本次执行的是代码审查（bmad-code-review），无论结论如何，必须执行以下步骤后才能退出：
- 步骤A：将审查结论（通过/发现问题+问题列表）写入对应的 Story 文件（如 _bmad-output/implementation-artifacts/CORE-005.md），更新其 status 字段
- 步骤B：执行 git add -A && git commit -m 'docs([story-id]): code review findings [skip ci]'
- 步骤C：执行 git push
绝对禁止仅将审查结论输出到终端而不写入文件和提交。没有 commit 等于本次执行无效。

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

AFTER_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ -n "$BEFORE_COMMIT" ] && [ "$BEFORE_COMMIT" = "$AFTER_COMMIT" ]; then
    log_error "Pipeline 失败: 代码仓库没有任何新的 commit (避免 Completed 状态虚假成功)"
    exit 3
fi

log_section "流水线完成 ✓"
log_info "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
exit 0
