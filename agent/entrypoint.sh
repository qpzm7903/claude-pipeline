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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}════════════════════════════════════════\n  $*\n════════════════════════════════════════${NC}\n"; }

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

# 格式化 claude stream-json 输出（保留全部事件，JSON 美化打印，展开换行符）
_fmt_stream() {
  python3 -u -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        formatted = json.dumps(json.loads(line), ensure_ascii=False, indent=2)
        print(formatted.replace('\\\\n', '\n'), flush=True)
    except json.JSONDecodeError:
        print(line, flush=True)
"
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
  REVIEW_PROMPT="你是一名独立代码审查员，对实现过程一无所知，只看结果。

## 审查范围
git diff origin/$(git symbolic-ref --short HEAD 2>/dev/null || echo main)...HEAD

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
    log_info "BMAD 阶段循环 #${PHASE_COUNT}: ${BMAD_PHASE}"

    IMPL_DIR="./_bmad-output/implementation-artifacts"
    STATUS_FILE="${IMPL_DIR}/sprint-status.yaml"
    DEFAULT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)
    git pull --rebase origin "$DEFAULT_BRANCH" 2>/dev/null || true

    case "$BMAD_PHASE" in
      discover)
        if [ ! -f "$STATUS_FILE" ]; then
          BMAD_PHASE="planning"
        else
          # 找第一个 ready-for-dev story
          STATUS_LINE=$(grep -n 'status:\s*ready-for-dev' "$STATUS_FILE" | head -1 | cut -d: -f1 || true)
          STORY_KEY=""
          if [ -n "$STATUS_LINE" ]; then
            STORY_KEY=$(head -n "$STATUS_LINE" "$STATUS_FILE" \
                        | grep 'id:' | tail -1 \
                        | sed 's/.*id:\s*//' | tr -d '"' | tr -d ' ')
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
        BMAD_PHASE="discover"
        ;;

      create-story)
        if [ "${READINESS_CHECKED}" != "true" ]; then
          run_readiness_check
          READINESS_CHECKED=true
        fi
        run_bmad_create_story
        BMAD_PHASE="discover"
        ;;

      claim)
        # 原子认领：status: ready-for-dev → in-progress
        python3 -c "
import re, sys
content = open('${STATUS_FILE}').read()
pattern = r'(id:\s*${STORY_KEY}.*?status:\s*)ready-for-dev'
result = re.sub(pattern, r'\1in-progress', content, count=1, flags=re.DOTALL)
open('${STATUS_FILE}', 'w').write(result)
"
        # 找对应 story 文件
        STORY_FILE_PATH=$(find "$IMPL_DIR" -name "${STORY_KEY}*.md" 2>/dev/null | head -1)
        if [ -z "$STORY_FILE_PATH" ]; then
          log_warning "story 文件不存在（${STORY_KEY}），先创建 story..."
          git checkout "$STATUS_FILE"
          BMAD_PHASE="create-story"
          continue
        fi

        git add "$STATUS_FILE"
        git commit -m "chore: claim story ${STORY_KEY} [skip ci]" --no-verify 2>/dev/null

        if git push origin "$DEFAULT_BRANCH" 2>/dev/null; then
          export STORY_KEY="$STORY_KEY"
          export STORY_FILE="$STORY_FILE_PATH"
          log_success "成功认领 story: $STORY_KEY → $STORY_FILE"
          BMAD_PHASE="done"
        else
          log_warning "push 冲突，回退并重试..."
          git reset HEAD~1
          git checkout "$STATUS_FILE"
          sleep $((PHASE_COUNT * 2))
          BMAD_PHASE="discover"
        fi
        ;;
    esac
  done

  if [ "$PHASE_COUNT" -ge "$MAX_PHASE_LOOPS" ]; then
    log_error "BMAD 阶段循环超过 ${MAX_PHASE_LOOPS} 次，异常退出"
    exit 1
  fi

else
  # ── 非 BMAD 项目：保留原 plan.md 逻辑 ─────────────────────────
  if [ -z "${TASK_ID:-}" ]; then
    MAX_CLAIM_RETRIES=5
    CLAIM_SUCCESS=false
    for attempt in $(seq 1 $MAX_CLAIM_RETRIES); do
      DEFAULT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)
      git pull --rebase origin "$DEFAULT_BRANCH" 2>/dev/null || true

      TASK_LINE=$(grep -n '^\- \[ \]' plan.md 2>/dev/null | head -1)
      if [ -z "$TASK_LINE" ]; then
        log_info "plan.md 中没有待处理任务（[ ]），容器正常退出"
        exit 0
      fi

      LINE_NUM=$(echo "$TASK_LINE" | cut -d: -f1)
      RAW_ID=$(echo "$TASK_LINE" | grep -oP 'id:\K\w+' || true)
      [ -z "$RAW_ID" ] && RAW_ID=$(echo "$TASK_LINE" | md5sum | cut -c1-8)

      sed -i "${LINE_NUM}s/^\- \[ \]/- [-]/" plan.md
      git add plan.md
      git commit -m "chore: claim task ${RAW_ID} [skip ci]" --no-verify 2>/dev/null

      if git push origin "$DEFAULT_BRANCH" 2>/dev/null; then
        export TASK_ID="$RAW_ID"
        log_success "成功抢占任务: $TASK_ID"
        CLAIM_SUCCESS=true
        break
      else
        log_warning "push 冲突（attempt $attempt），回退并重试..."
        git reset HEAD~1
        git checkout plan.md
        sleep $((attempt * 2))
      fi
    done

    if [ "$CLAIM_SUCCESS" != "true" ]; then
      log_error "无法抢占任务（$MAX_CLAIM_RETRIES 次重试后失败）"
      exit 1
    fi
  fi
fi

# ── 步骤 2: Claude 自主执行 ──────────────────────────────────────

log_section "步骤 2: Claude 自主执行"

if [ "$IS_BMAD" = "true" ]; then
  # ── BMAD 模式：读取 story 文件 + 遵循 dev-story workflow ──────
  PROMPT="你是一名资深软件工程师，按照 BMAD 开发工作流实现分配给你的 story。

## 你的任务
Story 文件：${STORY_FILE}
Story Key：${STORY_KEY}

## 执行步骤
0. 若 _bmad-output/project-context.md 存在，先阅读了解项目全局上下文
0.5. 若 _bmad-output/dev-log.md 存在，先阅读了解前序 story 的技术决策
1. 读取 ${STORY_FILE} 完整内容，理解 Story、Acceptance Criteria、Tasks
2. 读取 _bmad/bmm/config.yaml 了解项目配置
3. 读取 _bmad/bmm/workflows/4-implementation/dev-story/workflow.md，完整遵循其工作流指令
4. 按 workflow 实施 story（TDD、测试）
5. 实施完成后：
   - 将 ${STORY_FILE} 中 Status 字段改为 review（或 done，若已通过代码审查）
   - 将 _bmad-output/implementation-artifacts/sprint-status.yaml 中该 story 状态改为 review
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

完成所有实施和测试后，输出 PIPELINE_COMPLETE。"
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

# ── 步骤 2.5: dev-log + 独立审查 ─────────────────────────────────

# Opt6: BMAD story 完成后追加开发日志
if [ "$IS_BMAD" = "true" ] && [ -n "${STORY_KEY:-}" ]; then
    append_dev_log "$STORY_KEY"
fi

# Opt2: 独立代码审查（独立 Claude 调用，不复用实现上下文）
REVIEW_TASK_ID="${STORY_KEY:-${TASK_ID:-unknown}}"
run_independent_review "$REVIEW_TASK_ID"

# ── 步骤 3: 提交 + 推送 + PR ────────────────────────────────────────

log_section "步骤 3: 提交代码"

cd "${WORKSPACE}"
git add -A

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# 如果有未提交的变更，先 commit
if ! git diff --cached --quiet; then
    REVIEW_VERDICT=$(python3 -c "
import json, pathlib
p = pathlib.Path('review_result.json')
print(json.loads(p.read_text()).get('verdict','unknown') if p.exists() else 'no-review')
" 2>/dev/null || echo "unknown")

    ACTUAL_TASK_ID=$(python3 -c "
import json, pathlib
p = pathlib.Path('review_result.json')
print(json.loads(p.read_text()).get('task_id','${TASK_ID:-unknown}') if p.exists() else '${TASK_ID:-unknown}')
" 2>/dev/null || echo "${TASK_ID:-unknown}")

    git commit -m "feat(task-${ACTUAL_TASK_ID}): automated implementation

Automated by Claude Pipeline
Review verdict: ${REVIEW_VERDICT}
Task-Id: ${ACTUAL_TASK_ID}"

    log_success "代码已提交（分支: ${CURRENT_BRANCH}）"
else
    log_info "无新变更需要提交（Claude 已在执行中自行提交）"
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
