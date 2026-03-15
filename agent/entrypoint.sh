#!/usr/bin/env bash
# entrypoint.sh - Claude Pipeline Agent
#
# bash 只做三件事：
#   1. 克隆仓库 + 创建分支
#   2. 启动 Claude（读 plan.md 或 BMAD story → 自主决策 → 实施）
#   3. 独立审查 + 提交代码 + 推送 + 创建 PR + 反馈闭环
#
# 容器启动只需 REPO_URL + TASK_ID（最小标识）+ 认证信息。
# 任务详情、分支策略、技术栈、测试命令全部由 Claude 在容器内自主发现。

set -euo pipefail

# ── 日志持久化：双写到 cargo-cache PVC，不用 tee 避免 SIGPIPE 杀死脚本 ──────
_LOG_DIR="/home/pipeline/.cargo/registry/pipeline-logs"
_LOG_FILE="/dev/null"
# pipeline-logs 目录需提前设为 1777（kubectl 一次性操作），此处仅创建（若不存在）
mkdir -p "${_LOG_DIR}" 2>/dev/null || true
if [ -d "${_LOG_DIR}" ] && [ -w "${_LOG_DIR}" ]; then
  _LOG_FILE="${_LOG_DIR}/$(date +%Y%m%d-%H%M%S)-$(hostname -s 2>/dev/null || echo pod).log"
  # 保留最近 30 个日志文件
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
log_info "Task ID:  ${TASK_ID:-(none)}"
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

# 克隆重试（网络抖动保护：最多 3 次，间隔指数退避）
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

# ── 公共函数 ──────────────────────────────────────────────────────

# 启动时将格式化脚本写入临时文件（避免 heredoc 与管道争抢 stdin）
cat > /tmp/fmt_stream.py << 'PYEOF'
import sys, json

TEXT_LIMIT    = 500   # PVC 日志不受终端宽度限制，适当加长
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

    # system init：只显示一行摘要
    if t == 'system':
        if obj.get('subtype') == 'init':
            p('  [session] model=' + str(obj.get('model','')) + '  cwd=' + str(obj.get('cwd','')))
        continue

    # assistant：文本 + tool call 紧凑显示
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

    # tool result：按类型分级显示
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

    # 含 content/file 的其他事件（glm 格式文件读取结果）
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

    # result（最终完成事件）
    if t == 'result':
        cost     = obj.get('cost_usd', 0) or 0
        turns    = obj.get('num_turns', 0)
        duration = (obj.get('duration_ms', 0) or 0) // 1000
        subtype  = obj.get('subtype', '')
        p('  [done] ' + subtype + '  turns=' + str(turns) + '  cost=$' + '{:.4f}'.format(cost) + '  ' + str(duration) + 's')
        continue

    # 其他事件：静默丢弃
PYEOF

# 格式化 claude stream-json 输出，同时写入 PVC 日志文件
# 用 while read 双写而非 tee -a，避免写入失败触发 SIGPIPE 杀上游 claude 进程
_fmt_stream() {
  python3 -u /tmp/fmt_stream.py 2>&1 | while IFS= read -r _fmtline; do
    echo "$_fmtline"
    echo "$_fmtline" >> "${_LOG_FILE:-/dev/null}" 2>/dev/null || true
  done
}

# BMAD 规划阶段：生成 PRD / architecture / sprint-status.yaml + project-context.md
run_bmad_planning() {
  log_section "BMAD 规划阶段"
  PLANNING_PROMPT="你是 BMAD 产品经理兼架构师，负责为仓库自动生成规划文档和第一批开发故事。

首先读取 _bmad/bmm/config.yaml 了解项目配置。

然后按以下决策树执行：

1. 若 _bmad-output/planning-artifacts/PRD.md 不存在：
   → 阅读 _bmad/bmm/workflows/ 下的规划工作流文件
   → 分析项目（README、现有代码、已完成工作）
   → 按照工作流创建 PRD.md、architecture.md
   → 创建 _bmad-output/planning-artifacts/epics.md（列出所有 epic 和 story 大纲）
   → 创建 _bmad-output/project-context.md，内容包括：
     - 项目技术栈及版本
     - 目录结构约定
     - 关键依赖及其用途
     - 编码规范和命名约定
     - 测试框架及运行命令
     - CI/CD 配置摘要

2. 若 PRD.md 存在但 sprint-status.yaml 不存在或没有任何 story：
   → 读取 epics.md，将所有 story 写入 _bmad-output/implementation-artifacts/sprint-status.yaml（初始状态为 backlog）
   → 格式参考已有的 sprint-status.yaml 模板
   → 若 _bmad-output/project-context.md 不存在，补充创建

3. 完成后：
   git add _bmad-output/
   git commit -m 'plan: BMAD auto-planning phase [skip ci]'
   git push origin \$(git symbolic-ref --short HEAD 2>/dev/null || echo main)

输出 BMAD_PLANNING_COMPLETE。"

  claude \
      --dangerously-skip-permissions --print --verbose \
      --output-format stream-json \
      <<< "$PLANNING_PROMPT" 2>&1 | _fmt_stream
  [ "${PIPESTATUS[0]}" -ne 0 ] && { log_error "BMAD 规划失败"; exit 2; }
  log_success "BMAD 规划完成"
}

# BMAD create-story 阶段：将 backlog story 提升为 ready-for-dev
run_bmad_create_story() {
  log_section "BMAD create-story 阶段"
  CREATE_STORY_PROMPT="你是 BMAD SM（Story Manager），负责将一个 backlog story 提升为 ready-for-dev 状态。

步骤：
1. 读取 _bmad/bmm/config.yaml 获取路径配置
2. 读取 _bmad-output/implementation-artifacts/sprint-status.yaml，找第一个 backlog story
3. 读取 _bmad/bmm/workflows/4-implementation/create-story/workflow.md，完整遵循其指令
4. 按工作流创建详细 story 文件到 _bmad-output/implementation-artifacts/
5. 将该 story 状态更新为 ready-for-dev 并保存 sprint-status.yaml
6. 提交：
   git add _bmad-output/
   git commit -m 'plan: create story {story_key} [skip ci]'
   git push origin \$(git symbolic-ref --short HEAD 2>/dev/null || echo main)

输出 BMAD_CREATE_STORY_COMPLETE。"

  claude \
      --dangerously-skip-permissions --print --verbose \
      --output-format stream-json \
      <<< "$CREATE_STORY_PROMPT" 2>&1 | _fmt_stream
  [ "${PIPESTATUS[0]}" -ne 0 ] && { log_error "create-story 失败"; exit 2; }
  log_success "create-story 完成"
}

# Opt6: Story 间上下文传递 — 追加开发日志
append_dev_log() {
  local story_key="$1"
  local log_file="${WORKSPACE}/_bmad-output/dev-log.md"
  DEVLOG_PROMPT="阅读本次 story ${story_key} 的实现代码变更（git diff HEAD~1），提取：
1. 关键技术决策及理由
2. 遇到的问题及解决方案
3. 对后续 story 有参考价值的约定
以 markdown 追加到 ${log_file}，每条含 story key 和时间戳，限 200 字。
完成后：git add ${log_file} && git commit -m 'docs: dev-log for ${story_key} [skip ci]' && git push origin \$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"

  claude --dangerously-skip-permissions --print --verbose \
      --output-format stream-json <<< "$DEVLOG_PROMPT" 2>&1 | _fmt_stream
  log_info "dev-log 已更新 (story: ${story_key})"
}

# Opt5: 实施就绪检查
run_readiness_check() {
  log_section "BMAD 实施就绪检查"
  READINESS_PROMPT="你是 BMAD 质量门禁检查员。
检查 _bmad-output/planning-artifacts/ 下 PRD.md、architecture.md、epics.md 的一致性：
- PRD 功能需求是否都在 epics 中有对应 story
- architecture 技术选型是否与 PRD 匹配
- story 粒度是否合理（每个≤1天工作量）
- 是否有缺失的非功能需求

输出 /workspace/readiness_check.json：{\"ready\": true|false, \"issues\": [...], \"suggestions\": [...]}
若 ready=false，自动修复并重新提交。
完成后：git add _bmad-output/ && git commit -m 'plan: readiness check fixes [skip ci]' && git push origin \$(git symbolic-ref --short HEAD 2>/dev/null || echo main)"

  claude --dangerously-skip-permissions --print --verbose \
      --output-format stream-json <<< "$READINESS_PROMPT" 2>&1 | _fmt_stream
  [ "${PIPESTATUS[0]}" -ne 0 ] && { log_error "就绪检查失败"; exit 2; }
  log_success "就绪检查完成"
}

# Opt2: 独立代码审查（独立 Claude 调用，不复用实现上下文）
run_independent_review() {
  local task_id="$1"
  log_section "步骤 2.5: 独立代码审查"
  REVIEW_PROMPT="重要：你是这段代码的第一个也是唯一的读者，你对实现过程一无所知。
禁止使用「根据上下文我猜测作者的意图」等表述。
只根据代码本身（diff + story 验收标准）进行评判，不得引用任何会话历史或实现者视角。

你是一名独立代码审查员，对实现过程一无所知，只看结果。

## 审查范围
git diff ${BEFORE_IMPL_SHA:-HEAD~1}..HEAD

## 审查标准
1. 正确性：是否正确实现需求（参考 story 文件或 plan.md）
2. 安全性：注入、硬编码密钥、不安全依赖
3. 性能：O(n²)循环、内存泄漏、无限递归
4. 可维护性：命名、结构、注释
5. 测试覆盖：关键逻辑是否有测试

## 输出
写入 /workspace/review_result.json：
{\"task_id\": \"${task_id}\", \"title\": \"<标题>\", \"verdict\": \"pass|fail\", \"score\": 0-100, \"summary\": \"总结\", \"issues\": [...], \"strengths\": [...], \"recommendation\": \"approve|request_changes\"}

verdict=fail 时自动修复所有 high severity 问题，然后重新审查更新 review_result.json。
修复后：git add -A && git commit -m 'fix: address review issues for ${task_id}'
输出 REVIEW_COMPLETE。"

  claude --dangerously-skip-permissions --print --verbose \
      --output-format stream-json <<< "$REVIEW_PROMPT" 2>&1 | _fmt_stream
  [ "${PIPESTATUS[0]}" -ne 0 ] && log_warning "独立审查失败，继续流程" || log_success "独立代码审查完成"
}

# Opt4: PR 反馈闭环 — 等待 CI + review，自动修复
run_pr_feedback_loop() {
  local pr_number="$1"
  local max_retries="${2:-2}"
  log_section "步骤 4: PR 反馈循环"

  for attempt in $(seq 1 "$max_retries"); do
    log_info "反馈检查 #${attempt}..."
    # 等待 CI 完成（最多 10 分钟）
    local ci_wait=0 ci_status="pending"
    while [ "$ci_wait" -lt 600 ] && [ "$ci_status" = "pending" ]; do
      sleep 30; ci_wait=$((ci_wait + 30))
      OWNER_REPO=$(echo "$REPO_URL" | sed 's|.*github\.com/||;s|\.git$||')
      ci_status=$(python3 -c "
import urllib.request, json, os
url = f'https://api.github.com/repos/${OWNER_REPO}/commits/${CURRENT_BRANCH}/status'
req = urllib.request.Request(url, headers={'Authorization': f'token {os.environ.get(\"GIT_TOKEN\",\"\")}', 'Accept': 'application/vnd.github.v3+json', 'User-Agent': 'claude-pipeline'})
try: print(json.loads(urllib.request.urlopen(req,timeout=10).read()).get('state','unknown'))
except: print('unknown')
" 2>/dev/null || echo "unknown")
      log_info "CI: ${ci_status} (${ci_wait}s)"
    done

    # 获取 review comments
    review_comments=$(python3 -c "
import urllib.request, json, os
url = f'https://api.github.com/repos/${OWNER_REPO}/pulls/${pr_number}/reviews'
req = urllib.request.Request(url, headers={'Authorization': f'token {os.environ.get(\"GIT_TOKEN\",\"\")}', 'Accept': 'application/vnd.github.v3+json', 'User-Agent': 'claude-pipeline'})
try:
    reviews = json.loads(urllib.request.urlopen(req,timeout=10).read())
    changes = [r.get('body','') for r in reviews if r.get('state')=='CHANGES_REQUESTED']
    print('\n---\n'.join(changes) if changes else '')
except: print('')
" 2>/dev/null || echo "")

    local needs_fix=false fix_context=""
    [ "$ci_status" = "failure" ] || [ "$ci_status" = "error" ] && { needs_fix=true; fix_context="CI 检查失败，查看日志修复。"; }
    [ -n "$review_comments" ] && { needs_fix=true; fix_context="${fix_context}\nPR 审查员要求修改：\n${review_comments}"; }

    if [ "$needs_fix" = "false" ]; then
      log_success "PR 检查通过"; return 0
    fi

    log_warning "需要修复 (${attempt}/${max_retries})"
    FIX_PROMPT="你是修复工程师。问题：\n${fix_context}\n\n请分析根因、修复代码、运行测试、git add -A && git commit -m 'fix: address feedback (attempt ${attempt})'\n输出 FIX_COMPLETE"
    claude --dangerously-skip-permissions --print --verbose \
        --output-format stream-json <<< "$FIX_PROMPT" 2>&1 | _fmt_stream
    [ "${PIPESTATUS[0]}" -ne 0 ] && { log_warning "修复调用失败"; break; }
    git push --force origin "${CURRENT_BRANCH}"
  done
}

# 等待 Tag 触发的 GitHub Actions workflow 完成（用 workflow_runs API，不是 check-runs）
# check-runs API 对 tag push 触发的 release workflow 不可靠（常返回空 → 一直 pending）
wait_for_tag_ci() {
  local tag="$1"
  local max_wait="${2:-300}"
  local interval=20
  local elapsed=0

  log_section "等待 Release CI 完成 (tag: ${tag})"

  # GitHub 注册 workflow run 需要约 10s
  sleep 10; elapsed=10

  while [ "$elapsed" -lt "$max_wait" ]; do
    # gh run list 用 workflow_runs API，对 tag ref 更可靠
    run_status=$(gh run list \
      --repo "$(echo "$REPO_URL" | sed 's|.*github\.com/||;s|\.git$||')" \
      --branch "${tag}" \
      --limit 5 \
      --json status,conclusion \
      --jq '[.[] | {s:.status, c:.conclusion}]' 2>/dev/null || echo "[]")

    total=$(echo "$run_status" | python3 -c "import json,sys; runs=json.load(sys.stdin); print(len(runs))" 2>/dev/null || echo "0")
    if [ "$total" = "0" ]; then
      if [ "$elapsed" -ge 60 ]; then
        log_info "60s 内未发现 Release workflow run，跳过 CI 等待（该 repo 可能未配置 tag CI）"
        return 0
      fi
    else
      ci_result=$(echo "$run_status" | python3 -c "
import json, sys
runs = json.load(sys.stdin)
if all(r['s'] == 'completed' for r in runs):
    bad = [r for r in runs if r['c'] not in ('success','skipped','neutral')]
    print('failure' if bad else 'success')
else:
    print('pending')
" 2>/dev/null || echo "pending")
      log_info "Release CI: ${ci_result} (${elapsed}s / ${max_wait}s, runs=${total})"
      case "$ci_result" in
        success) log_success "Release CI 全部通过"; return 0 ;;
        failure) log_error "Release CI 失败"; return 1 ;;
      esac
    fi

    sleep "$interval"; elapsed=$((elapsed + interval))
  done

  log_warning "Release CI 等待超时 (${max_wait}s)，继续流程（不视为失败）"
  return 2  # 超时但不是失败（避免创建假 issue）
}

# 等待目标仓库 GitHub Actions 完成（check-runs API 比旧 /status 精确）
wait_for_branch_ci() {
  local branch="$1"
  local max_wait="${2:-600}"
  local interval=30
  local elapsed=0
  local OWNER_REPO
  OWNER_REPO=$(echo "$REPO_URL" | sed 's|.*github\.com/||;s|\.git$||')

  log_section "等待 GitHub Actions 完成 (branch: ${branch})"

  while [ "$elapsed" -lt "$max_wait" ]; do
    ci_status=$(python3 -c "
import urllib.request, json, os
url = 'https://api.github.com/repos/${OWNER_REPO}/commits/${branch}/check-runs'
req = urllib.request.Request(url, headers={
    'Authorization': f'token {os.environ.get(\"GIT_TOKEN\",\"\")}',
    'Accept': 'application/vnd.github.v3+json',
    'User-Agent': 'claude-pipeline'
})
try:
    data = json.loads(urllib.request.urlopen(req, timeout=10).read())
    runs = data.get('check_runs', [])
    if not runs:
        print('pending')
    elif all(r['status'] == 'completed' for r in runs):
        bad = [r for r in runs if r['conclusion'] not in ('success','skipped','neutral')]
        print('failure' if bad else 'success')
    else:
        print('pending')
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")

    log_info "CI 状态: ${ci_status} (${elapsed}s / ${max_wait}s)"
    case "$ci_status" in
      success) log_success "GitHub Actions 全部通过"; return 0 ;;
      failure) log_error "GitHub Actions 失败"; return 1 ;;
    esac
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  log_error "等待 CI 超时 (${max_wait}s)"
  return 1
}

# 获取失败 job 摘要（最多 3 个）
fetch_ci_failure_logs() {
  local branch="$1"
  local OWNER_REPO
  OWNER_REPO=$(echo "$REPO_URL" | sed 's|.*github\.com/||;s|\.git$||')

  python3 -c "
import urllib.request, json, os
url = 'https://api.github.com/repos/${OWNER_REPO}/commits/${branch}/check-runs'
headers = {
    'Authorization': f'token {os.environ.get(\"GIT_TOKEN\",\"\")}',
    'Accept': 'application/vnd.github.v3+json',
    'User-Agent': 'claude-pipeline'
}
try:
    data = json.loads(urllib.request.urlopen(
        urllib.request.Request(url, headers=headers), timeout=10).read())
    failed = [r for r in data.get('check_runs',[])
              if r.get('conclusion') not in ('success','skipped','neutral',None)]
    summary = []
    for r in failed[:3]:
        summary.append(f\"Job: {r.get('name')} | URL: {r.get('html_url')}\")
    print('\n'.join(summary) if summary else 'No failed jobs found')
except Exception as e:
    print(f'Failed to fetch logs: {e}')
" 2>/dev/null || echo "Unable to fetch CI logs"
}


# CI 失败时创建 GitHub Issue（label: pipeline-ci-failure）
create_ci_failure_issue() {
  local story_key="$1"
  local tag_name="$2"
  local ci_logs="$3"
  local OWNER_REPO
  OWNER_REPO=$(echo "$REPO_URL" | sed 's|.*github\.com/||;s|\.git$||')

  # 确保 label 存在（首次运行时创建）
  gh label create "pipeline-ci-failure" --color "d93f0b" \
    --description "CI failure tracked by pipeline" \
    --repo "$OWNER_REPO" 2>/dev/null || true

  # 创建 issue
  ISSUE_URL=$(gh issue create \
    --repo "$OWNER_REPO" \
    --title "CI failure: ${story_key} (${tag_name})" \
    --label "pipeline-ci-failure" \
    --body "## CI 失败报告

**Story**: ${story_key}
**Tag**: ${tag_name}

## 失败摘要
\`\`\`
${ci_logs}
\`\`\`

*由 Claude Pipeline 自动创建*" 2>/dev/null || echo "")

  log_warning "CI 失败，已创建 issue: ${ISSUE_URL}"
  echo "$ISSUE_URL" > /workspace/ci_failure_issue.txt
}

# ── 步骤 1.5: 任务发现与认领 ─────────────────────────────────────
log_section "步骤 1.5: 任务发现与认领"

IS_BMAD=false
[ -d "./_bmad" ] && IS_BMAD=true

if [ "$IS_BMAD" = "true" ]; then
  # ── BMAD 项目路径：阶段循环状态机 ──────────────────────────────
  BMAD_PHASE="discover"
  MAX_PHASE_LOOPS=5
  PHASE_COUNT=0
  READINESS_CHECKED=false

  while [ "$BMAD_PHASE" != "done" ] && [ "$PHASE_COUNT" -lt "$MAX_PHASE_LOOPS" ]; do
    PHASE_COUNT=$((PHASE_COUNT + 1))
    BMAD_PHASE_LAST="$BMAD_PHASE"
    log_info "BMAD 阶段循环 #${PHASE_COUNT}: ${BMAD_PHASE}"

    IMPL_DIR="./_bmad-output/implementation-artifacts"
    STATUS_FILE="${IMPL_DIR}/sprint-status.yaml"
    DEFAULT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)
    git pull --rebase origin "$DEFAULT_BRANCH" 2>/dev/null || true

    case "$BMAD_PHASE" in
      discover)
        # 最高优先：检查是否有未解决的 CI failure issue
        OPEN_CI_ISSUE=$(gh issue list \
          --label "pipeline-ci-failure" \
          --state open \
          --json number,title \
          --limit 1 \
          --jq '.[0]' 2>/dev/null || echo "")

        if [ -n "$OPEN_CI_ISSUE" ] && [ "$OPEN_CI_ISSUE" != "null" ]; then
          log_info "发现未解决的 CI failure issue，优先修复"
          BMAD_PHASE="ci-fix"
        elif [ ! -f "$STATUS_FILE" ]; then
          BMAD_PHASE="planning"
        else
          STORY_KEY=""

          # 优先：找 in-progress story 且 story 文件内还有待做 task（[ ]）
          while IFS= read -r line; do
            line_num=$(echo "$line" | cut -d: -f1)
            candidate=$(head -n "$line_num" "$STATUS_FILE" \
                        | grep 'id:' | tail -1 \
                        | sed 's/.*id:\s*//' | tr -d '"' | tr -d ' ')
            candidate_file=$(find "$IMPL_DIR" -name "${candidate}*.md" 2>/dev/null | head -1)
            if [ -n "$candidate_file" ] && grep -q '^\- \[ \]' "$candidate_file" 2>/dev/null; then
              STORY_KEY="$candidate"
              break
            fi
          done < <(grep -n 'status:\s*in-progress' "$STATUS_FILE" 2>/dev/null || true)

          # 次选：找 ready-for-dev story
          if [ -z "$STORY_KEY" ]; then
            STATUS_LINE=$(grep -n 'status:\s*ready-for-dev' "$STATUS_FILE" | head -1 | cut -d: -f1 || true)
            if [ -n "$STATUS_LINE" ]; then
              STORY_KEY=$(head -n "$STATUS_LINE" "$STATUS_FILE" \
                          | grep 'id:' | tail -1 \
                          | sed 's/.*id:\s*//' | tr -d '"' | tr -d ' ')
            fi
          fi

          if [ -n "$STORY_KEY" ]; then
            BMAD_PHASE="claim"
          else
            HAS_BACKLOG=$(grep -c 'status:\s*backlog' "$STATUS_FILE" || true)
            if [ "$HAS_BACKLOG" -gt 0 ]; then
              BMAD_PHASE="create-story"
            else
              BMAD_PHASE="planning"  # 所有 story 完成，重新规划
            fi
          fi
        fi
        ;;

      planning)
        run_bmad_planning
        BMAD_PHASE="done"  # 一次容器只做一件事：规划完即退出
        ;;

      create-story)
        if [ "${READINESS_CHECKED}" != "true" ]; then
          run_readiness_check
          READINESS_CHECKED=true
        fi
        run_bmad_create_story
        BMAD_PHASE="done"  # 一次容器只做一件事：创建 story 后退出，下次触发再认领
        ;;

      claim)
        # 找 story 文件
        STORY_FILE_PATH=$(find "$IMPL_DIR" -name "${STORY_KEY}*.md" 2>/dev/null | head -1)
        if [ -z "$STORY_FILE_PATH" ]; then
          log_warning "story 文件不存在（${STORY_KEY}），先创建 story..."
          BMAD_PHASE="create-story"
          continue
        fi

        # 若 story 仍是 ready-for-dev，先标记为 in-progress
        python3 -c "
import re
content = open('${STATUS_FILE}').read()
result = re.sub(r'(id:\s*${STORY_KEY}.*?status:\s*)ready-for-dev',
                r'\1in-progress', content, count=1, flags=re.DOTALL)
open('${STATUS_FILE}', 'w').write(result)
" 2>/dev/null || true

        # 原子认领 story 内第一个待做 task（[ ] → [-]）
        TASK_LINE_RAW=$(grep -n '^\- \[ \]' "$STORY_FILE_PATH" | head -1)
        if [ -z "$TASK_LINE_RAW" ]; then
          log_warning "story ${STORY_KEY} 没有待做 task，标记为 review 后退出"
          python3 -c "
import re
content = open('${STATUS_FILE}').read()
result = re.sub(r'(id:\s*${STORY_KEY}.*?status:\s*)in-progress',
                r'\1review', content, count=1, flags=re.DOTALL)
open('${STATUS_FILE}', 'w').write(result)
" 2>/dev/null || true
          git add "$STATUS_FILE"
          git commit -m "chore: mark ${STORY_KEY} review - all tasks done [skip ci]" --no-verify 2>/dev/null
          git push origin "$DEFAULT_BRANCH" 2>/dev/null || true
          exit 0
        fi

        TASK_LINE_NUM=$(echo "$TASK_LINE_RAW" | cut -d: -f1)
        TASK_DESC=$(echo "$TASK_LINE_RAW" | sed 's/^[0-9]*:- \[ \] *//')
        sed -i "${TASK_LINE_NUM}s/^\- \[ \]/- [-]/" "$STORY_FILE_PATH"

        git add "$STATUS_FILE" "$STORY_FILE_PATH"
        git commit -m "chore: claim task in ${STORY_KEY}: ${TASK_DESC} [skip ci]" --no-verify 2>/dev/null
        git push origin "$DEFAULT_BRANCH" 2>/dev/null || log_warning "push 认领标记失败，继续执行"

        export STORY_KEY="$STORY_KEY"
        export STORY_FILE="$STORY_FILE_PATH"
        export TASK_DESC="$TASK_DESC"
        export TASK_LINE_NUM="$TASK_LINE_NUM"
        log_success "认领 task: [${STORY_KEY}] ${TASK_DESC}"
        BMAD_PHASE="done"
        ;;

      ci-fix)
        CI_ISSUE_NUM=$(gh issue list \
          --label "pipeline-ci-failure" \
          --state open \
          --json number --jq '.[0].number' 2>/dev/null || echo "")
        if [ -z "$CI_ISSUE_NUM" ]; then
          log_warning "未找到 pipeline-ci-failure issue，跳过修复"
          BMAD_PHASE="done"
          break
        fi
        CI_ISSUE_BODY=$(gh issue view "$CI_ISSUE_NUM" --json body --jq '.body' 2>/dev/null || echo "")

        log_section "修复 CI failure issue #${CI_ISSUE_NUM}"

        CI_FIX_PROMPT="你是一名资深工程师，需要修复以下 CI 失败：

## Issue 内容
${CI_ISSUE_BODY}

## 执行步骤
1. 用 gh run list / gh run view 获取完整 CI 日志
2. 分析根因
3. 修复代码（遵循现有代码风格）
4. 运行本地测试验证修复
5. git add -A && git commit -m 'fix: resolve CI failure for issue #${CI_ISSUE_NUM}'
6. 关闭 issue：gh issue close ${CI_ISSUE_NUM} --comment '已修复'
7. 输出 PIPELINE_COMPLETE"

        claude --dangerously-skip-permissions --print --verbose \
          --output-format stream-json <<< "$CI_FIX_PROMPT" 2>&1 | _fmt_stream
        [ "${PIPESTATUS[0]}" -ne 0 ] && log_warning "CI 修复调用失败，继续流程"

        BMAD_PHASE="done"
        ;;

    esac
  done

  if [ "$PHASE_COUNT" -ge "$MAX_PHASE_LOOPS" ]; then
    log_error "BMAD 阶段循环超过 ${MAX_PHASE_LOOPS} 次，异常退出"
    exit 1
  fi

else
  # ── 非 BMAD 项目：plan.md 逻辑 ─────────────────────────────────
  TASK_MODE="normal"

  if [ -z "${TASK_ID:-}" ]; then
    DEFAULT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)
    git pull --rebase origin "$DEFAULT_BRANCH" 2>/dev/null || true

    TASK_LINE=$(grep -n '^\- \[ \]' plan.md 2>/dev/null | head -1)

    if [ -z "$TASK_LINE" ]; then
      log_info "plan.md 中没有待处理任务，容器正常退出"
      exit 0
    fi

    LINE_NUM=$(echo "$TASK_LINE" | cut -d: -f1)
    RAW_ID=$(echo "$TASK_LINE" | grep -oP 'id:\K\w+' || true)
    [ -z "$RAW_ID" ] && RAW_ID=$(echo "$TASK_LINE" | md5sum | cut -c1-8)

    sed -i "${LINE_NUM}s/^\- \[ \]/- [-]/" plan.md
    git add plan.md
    git commit -m "chore: claim task ${RAW_ID} [skip ci]" --no-verify 2>/dev/null
    git push origin "$DEFAULT_BRANCH" 2>/dev/null || log_warning "push 认领标记失败，继续执行"
    export TASK_ID="$RAW_ID"
    log_success "认领任务: $TASK_ID"
  fi
fi

# ── 步骤 2: Claude 自主执行 ──────────────────────────────────────

# BMAD 模式下，若本次只做了 planning/create-story/ci-fix，没有认领 story，直接退出
if [ "$IS_BMAD" = "true" ] && [ -z "${STORY_KEY:-}" ]; then
  case "${BMAD_PHASE_LAST:-}" in
    ci-fix)   log_info "本次运行已完成 CI 修复，等待下次调度认领实施" ;;
    planning) log_info "本次运行已完成规划，等待下次调度创建 story" ;;
    *)        log_info "本次运行已完成 story 准备工作，等待下次调度认领实施" ;;
  esac
  exit 0
fi

log_section "步骤 2: Claude 自主执行"

# 记录实现前的 commit SHA，供独立审查使用（Claude push 后 origin/HEAD 会追上，必须提前捕获）
BEFORE_IMPL_SHA=$(git rev-parse HEAD)

if [ "$IS_BMAD" = "true" ]; then
  # ── BMAD 模式：只实施 story 内当前认领的单个 task ──────────────
  PROMPT="你是一名资深软件工程师，按照 BMAD 开发工作流实施 story 内的一个 task。

## 本次任务（只做这一个）
- Story 文件：${STORY_FILE}
- Story Key：${STORY_KEY}
- 当前 Task（已标记为 [-]）：${TASK_DESC}

## 执行步骤
0. 若 _bmad-output/project-context.md 存在，先阅读了解项目全局上下文
0.5. 若 _bmad-output/dev-log.md 存在，先阅读了解前序技术决策
1. 读取 ${STORY_FILE} 完整内容，理解 Story、Acceptance Criteria 以及所有 Tasks（了解上下文，但本次只实施当前 task）
2. 读取 _bmad/bmm/config.yaml 了解项目配置
3. 实施当前 task：${TASK_DESC}
   - 遵循 TDD，先写测试再写实现
   - 只修改与该 task 直接相关的代码
   - **Rust 测试注意**：若 Cargo.toml 含屏幕捕获依赖（xcap/pipewire/libspa），直接用 \`cargo test --no-default-features\`，禁止先跑默认 features 再因报错重试
4. 更新 story 文件状态：
   a. 将 ${STORY_FILE} 中该 task 的 [-] 改为 [x]
   b. 检查 ${STORY_FILE} 中是否还有 [ ] 未做 task：
      - 若还有未做 task：不修改 story Status，不修改 sprint-status.yaml
      - 若所有 task 均已 [x]：将 Status 改为 review，并将 sprint-status.yaml 中该 story 状态改为 review
5. **【必须执行，不可跳过】提交代码**：
   \`\`\`
   git add -A
   git commit -m \"<type>(<scope>): <简洁描述本次实际变更>\"
   \`\`\`
   遵循 Conventional Commits 规范（feat/fix/chore/test/docs 等）。
   若跳过此步骤，pipeline 日志将记录 'Claude 未自行提交' 警告，请务必执行。
6. 最后输出 PIPELINE_COMPLETE"

else
  # ── 非 BMAD 模式：保留现有通用 prompt ────────────────────────
  TASK_HINT="当前分配给你的任务 ID 是 **${TASK_ID}**。请在 plan.md 中找到该任务并完成它。任务在 plan.md 中目前标记为 [-]（进行中），完成后请改为 [x]。"

  PROMPT="你是一名资深软件工程师，独立负责完成仓库中的开发任务。

## 任务定位
${TASK_HINT}

---

## 你的工作流程

### 第一步：探索仓库（必须执行）

在做任何事情之前，彻底理解这个仓库：
- 阅读 plan.md，找到你的目标任务（注意任务的 id、标题、spec 路径等元数据）
- 若任务有关联的 spec 文件（plan.md 中的 spec: 字段），读取其完整内容
- 阅读 README.md 以及 package.json/Cargo.toml/pyproject.toml 等配置文件
- 查看目录结构，理解代码架构和技术栈
- 确定项目的测试命令（cargo test / pytest / npm test 等）

**GitHub Issues 检查**：
运行 \`gh issue list --state open --limit 20\` 查看所有 open issues。
若发现与当前任务相关或力所能及的 issue，纳入后续计划一并处理。

### 第二步：创建工作分支

根据任务 ID 创建分支：git checkout -b task/<task_id>

### BMAD 检测（必须执行）

在第二步创建分支后，检查仓库是否使用 BMAD：
- 查找 .claude/skills/ 目录下是否有 bmad-* 文件夹
- 查找 CLAUDE.md 中是否有 \"BMAD\" 字样
- 查找 prompt.md 中是否有 \"BMAD\" 字样

如果仓库使用 BMAD（任一条件满足）：
- 在制定计划时使用 BMAD 结构化格式（澄清→规划→实施→审查→呈现）
- AGENT_PLAN.md 须包含：任务理解、验收条件确认、分步实施计划
- 严格遵循仓库的 CLAUDE.md 中的 BMAD 工作流规范

### 第三步：制定计划（必须写入文件）

将你的计划写入仓库根目录的 AGENT_PLAN.md：

1. **任务理解**：你对这个任务的理解（包括推断出的隐含需求）
2. **当前状态**：仓库现状，是否有相关代码、测试、文档
3. **行动计划**：具体的实施步骤（编号列表，越具体越好）
4. **技术决策**：你选择的技术方案及理由
5. **验证方式**：如何确认任务完成（包括使用什么测试命令）

### 第四步：实施

按照 AGENT_PLAN.md 执行。

关于 TDD：由你根据任务性质自主决定。功能开发推荐先写测试再实现；文档、配置、重构类任务按实际情况处理。

实施中：
- 如需安装系统软件包（gcc、build-essential 等），使用 \`sudo apt-get install -y\`；安装语言工具链（rustup、nvm 等）按各自官方方式安装
- 遇到需求不清晰的地方，根据仓库风格做出合理判断并记录在 AGENT_PLAN.md
- 完成后运行你在第一步中确定的测试命令，确认测试通过
- 测试通过后，将 plan.md 中对应任务的 \`[ ]\` 改为 \`[x]\`，标记任务完成
- **测试失败处理原则**：若测试因环境缺少系统级 GUI 库（如 gtk、webkit2gtk、pipewire、glib）而无法编译，**不要**反复尝试安装这类桌面图形依赖；改用 \`cargo test --lib\` 只测试纯逻辑部分，或跳过该测试直接完成其他工作并在 AGENT_PLAN.md 中注明原因。同一错误重试超过 2 次后立即换策略。

**Issue 处理**：对第一步中发现并纳入计划的每个 issue：
1. 开始修复前：gh issue comment <issue_number> --body '正在处理此 issue，将在本次 PR 中修复。'
2. 修复完成后：gh issue close <issue_number> --comment '已修复，见本 PR。'

### 第五步：完成

完成所有实施和测试后：
- git add -A && git commit（根据本次实际变更内容，写简洁有意义的 commit message，遵循 Conventional Commits 规范）
- 输出 PIPELINE_COMPLETE"
fi

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

# ── Story 完成检测 ────────────────────────────────────────────────
# 检查 story 文件中是否还有未完成 task（[ ] 待做 或 [-] 进行中）
STORY_COMPLETE=false
if [ "$IS_BMAD" = "true" ] && [ -n "${STORY_FILE:-}" ]; then
    if ! grep -q '^\- \[[ -]\]' "${STORY_FILE}" 2>/dev/null; then
        STORY_COMPLETE=true
        log_info "Story ${STORY_KEY} 全部 task 完成"
    fi
fi

# ── 步骤 2.5: dev-log + 独立审查 ─────────────────────────────────

# Opt6: BMAD story 完成后追加开发日志
if [ "$IS_BMAD" = "true" ] && [ -n "${STORY_KEY:-}" ]; then
    append_dev_log "$STORY_KEY"
fi

# Opt2: 独立代码审查（独立 Claude 调用，不复用实现上下文）
REVIEW_TASK_ID="${STORY_KEY:-${TASK_ID:-unknown}}"
run_independent_review "$REVIEW_TASK_ID"

# ── 步骤 3: 推送 + PR ──────────────────────────────────────────────
# Claude 应在步骤 2 中自行 commit，此处仅做安全兜底

log_section "步骤 3: 推送代码"

cd "${WORKSPACE}"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 安全兜底：若 Claude 遗漏了 commit，警告并补一个
git add -A
if ! git diff --cached --quiet; then
    log_warning "Claude 未自行提交，bash 兜底提交（建议检查 prompt）"
    FALLBACK_ID="${STORY_KEY:-${TASK_ID:-unknown}}"
    git commit -m "chore(${FALLBACK_ID}): fallback commit by pipeline [Claude did not commit]"
    log_success "兜底提交完成（分支: ${CURRENT_BRANCH}）"
else
    log_info "Claude 已自行提交，跳过兜底"
fi

# 无论是否新增 commit，只要本地有提交就推送
if [ -n "${GIT_TOKEN:-}" ]; then
    # 远端分支不存在时直接推送；存在时检查是否领先
    if ! git ls-remote --exit-code --heads origin "${CURRENT_BRANCH}" &>/dev/null; then
        SHOULD_PUSH=1
        log_info "远端分支不存在，将创建并推送"
    else
        UNPUSHED=$(git rev-list "origin/${CURRENT_BRANCH}..HEAD" --count 2>/dev/null || echo "0")
        SHOULD_PUSH=$(( UNPUSHED > 0 ? 1 : 0 ))
        [ "${SHOULD_PUSH}" -eq 0 ] && log_info "无未推送提交，跳过推送"
    fi

    if [ "${SHOULD_PUSH}" -eq 1 ]; then
        git push --force origin "${CURRENT_BRANCH}"
        log_success "已推送: ${CURRENT_BRANCH}"
        BRANCH_NAME="${CURRENT_BRANCH}" python3 /agent/create_pr.py
    fi
else
    log_warning "GIT_TOKEN 未设置，跳过推送"
    SHOULD_PUSH=0
fi

# ── 步骤 3.5: 仅 story 完成时打 tag + 等待 CI ───────────────────────

if [ "$IS_BMAD" = "true" ] && [ "${STORY_COMPLETE:-false}" = "true" ] && [ -n "${GIT_TOKEN:-}" ]; then
    TAG_NAME="v${STORY_KEY}-$(date -u +%Y%m%d-%H%M%S)"
    log_section "Story ${STORY_KEY} 完成，打 Release Tag: ${TAG_NAME}"

    git tag -a "$TAG_NAME" -m "Release story ${STORY_KEY}"
    if git push origin "$TAG_NAME" 2>/dev/null; then
        log_success "Tag 推送成功，GitHub Actions 将自动创建 Release"
        tag_ci_result=0
        wait_for_tag_ci "$TAG_NAME" 300 || tag_ci_result=$?
        if [ "$tag_ci_result" -eq 1 ]; then
            # 仅真正失败（非超时/无 CI）时才创建 issue
            CI_LOGS=$(fetch_ci_failure_logs "$TAG_NAME")
            create_ci_failure_issue "$STORY_KEY" "$TAG_NAME" "$CI_LOGS"
        fi
    else
        log_warning "Tag 推送失败，跳过 Release"
    fi
fi

# ── 步骤 4: PR 反馈循环 ──────────────────────────────────────────

PR_URL_FILE="/workspace/pr_url.txt"
if [ -f "$PR_URL_FILE" ]; then
    PR_NUM=$(basename "$(cat "$PR_URL_FILE")")
    run_pr_feedback_loop "$PR_NUM" 2
fi

log_section "流水线完成 ✓"
log_info "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
exit 0
