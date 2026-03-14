#!/usr/bin/env bash
# entrypoint.sh - Claude Pipeline Agent
#
# bash 只做三件事：
#   1. 克隆仓库 + 创建分支
#   2. 启动 Claude（读 plan.md 或 BMAD story → 自主决策 → 实施 → 审查）
#   3. 提交代码 + 推送 + 创建 PR
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

git clone --depth=20 "${AUTH_URL}" "${WORKSPACE}"
cd "${WORKSPACE}"
git config user.name  "${GIT_AUTHOR_NAME:-Claude Pipeline Bot}"
git config user.email "${GIT_AUTHOR_EMAIL:-pipeline@claude.ai}"
log_success "克隆完成"

# ── 公共函数 ──────────────────────────────────────────────────────


# BMAD 规划阶段：生成 PRD / architecture / sprint-status.yaml
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

2. 若 PRD.md 存在但 sprint-status.yaml 不存在或没有任何 story：
   → 读取 epics.md，将所有 story 写入 _bmad-output/implementation-artifacts/sprint-status.yaml（初始状态为 backlog）
   → 格式参考已有的 sprint-status.yaml 模板

3. 完成后：
   git add _bmad-output/
   git commit -m 'plan: BMAD auto-planning phase [skip ci]'
   git push origin \$(git symbolic-ref --short HEAD 2>/dev/null || echo main)

输出 BMAD_PLANNING_COMPLETE。"

  claude \
      --dangerously-skip-permissions --print --verbose \
      <<< "$PLANNING_PROMPT"
  [ $? -ne 0 ] && { log_error "BMAD 规划失败"; exit 2; }
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
      <<< "$CREATE_STORY_PROMPT"
  [ $? -ne 0 ] && { log_error "create-story 失败"; exit 2; }
  log_success "create-story 完成"
}

# ── 步骤 1.5: 任务发现与认领 ─────────────────────────────────────
log_section "步骤 1.5: 任务发现与认领"

IS_BMAD=false
[ -d "./_bmad" ] && IS_BMAD=true

if [ "$IS_BMAD" = "true" ]; then
  # ── BMAD 项目路径 ──────────────────────────────────────────────
  IMPL_DIR="./_bmad-output/implementation-artifacts"
  STATUS_FILE="${IMPL_DIR}/sprint-status.yaml"

  if [ -z "${STORY_FILE:-}" ]; then
    # 查找 ready-for-dev story（只有未指定时才自动发现）
    MAX_CLAIM_RETRIES=5
    CLAIM_SUCCESS=false

    for attempt in $(seq 1 $MAX_CLAIM_RETRIES); do
      DEFAULT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)
      git pull --rebase origin "$DEFAULT_BRANCH" 2>/dev/null || true

      if [ ! -f "$STATUS_FILE" ]; then
        log_info "未找到 sprint-status.yaml，进入 BMAD 规划模式..."
        run_bmad_planning
        exit 0
      fi

      # 找第一个 ready-for-dev story 的 id（兼容列表格式 YAML）
      # 先找 "status: ready-for-dev" 所在行号，再向上找最近的 "id:" 字段
      STATUS_LINE=$(grep -n 'status:\s*ready-for-dev' "$STATUS_FILE" | head -1 | cut -d: -f1 || true)
      STORY_KEY=""
      if [ -n "$STATUS_LINE" ]; then
        STORY_KEY=$(head -n "$STATUS_LINE" "$STATUS_FILE" \
                    | grep 'id:' | tail -1 \
                    | sed 's/.*id:\s*//' | tr -d '"' | tr -d ' ')
      fi

      if [ -z "$STORY_KEY" ]; then
        # 检查是否有 backlog story
        HAS_BACKLOG=$(grep -c 'status:\s*backlog' "$STATUS_FILE" || true)
        if [ "$HAS_BACKLOG" -gt 0 ]; then
          log_info "有 backlog story，运行 create-story 工作流..."
          run_bmad_create_story
          exit 0
        else
          log_info "所有 story 已完成，进入 BMAD 规划模式..."
          run_bmad_planning
          exit 0
        fi
      fi

      # 原子认领：把 status: ready-for-dev → status: in-progress（列表格式）
      # 定位该 story 块（从 id: STORY_KEY 到下一个 - id:），只改其中的 status 行
      python3 -c "
import re, sys
content = open('${STATUS_FILE}').read()
# 在 id: STORY_KEY 后最近的 status: ready-for-dev 替换为 in-progress
pattern = r'(id:\s*${STORY_KEY}.*?status:\s*)ready-for-dev'
result = re.sub(pattern, r'\1in-progress', content, count=1, flags=re.DOTALL)
open('${STATUS_FILE}', 'w').write(result)
"

      # 找对应 story 文件
      STORY_FILE_PATH=$(find "$IMPL_DIR" -name "${STORY_KEY}*.md" 2>/dev/null | head -1)
      if [ -z "$STORY_FILE_PATH" ]; then
        # story 文件还没创建，先 create-story
        log_warning "story 文件不存在（${STORY_KEY}），先创建 story..."
        git checkout "$STATUS_FILE"
        run_bmad_create_story
        exit 0
      fi

      git add "$STATUS_FILE"
      git commit -m "chore: claim story ${STORY_KEY} [skip ci]" --no-verify 2>/dev/null

      if git push origin "$DEFAULT_BRANCH" 2>/dev/null; then
        export STORY_KEY="$STORY_KEY"
        export STORY_FILE="$STORY_FILE_PATH"
        log_success "成功认领 story: $STORY_KEY → $STORY_FILE"
        CLAIM_SUCCESS=true
        break
      else
        log_warning "push 冲突（attempt $attempt），回退并重试..."
        git reset HEAD~1
        git checkout "$STATUS_FILE"
        sleep $((attempt * 2))
      fi
    done

    if [ "$CLAIM_SUCCESS" != "true" ]; then
      log_error "无法认领 story（$MAX_CLAIM_RETRIES 次后失败）"
      exit 1
    fi
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
1. 读取 ${STORY_FILE} 完整内容，理解 Story、Acceptance Criteria、Tasks
2. 读取 _bmad/bmm/config.yaml 了解项目配置
3. 读取 _bmad/bmm/workflows/4-implementation/dev-story/workflow.md，完整遵循其工作流指令
4. 按 workflow 实施 story（TDD、测试、代码审查）
5. 实施完成后：
   - 将 ${STORY_FILE} 中 Status 字段改为 review（或 done，若已通过代码审查）
   - 将 _bmad-output/implementation-artifacts/sprint-status.yaml 中该 story 状态改为 review
6. 输出 review_result.json（格式如下）
7. 最后输出 PIPELINE_COMPLETE

## review_result.json 格式
{\"task_id\": \"${STORY_KEY}\", \"title\": \"<story 标题>\", \"verdict\": \"pass|fail\", \"score\": 0-100, \"summary\": \"一两句话总结\", \"issues\": [{\"severity\": \"high|medium|low\", \"category\": \"correctness|security|performance|maintainability\", \"file\": \"路径\", \"line\": 行号, \"description\": \"问题\", \"suggestion\": \"建议\"}], \"strengths\": [\"做得好的地方\"], \"recommendation\": \"approve|request_changes\"}

verdict 规则：有任何 high severity 问题则为 fail，否则为 pass。"

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

### 第五步：代码审查并输出报告

将审查结果写入 /workspace/review_result.json：

{\"task_id\": \"<你完成的任务ID>\", \"title\": \"<任务标题>\", \"verdict\": \"pass|fail\", \"score\": 0-100, \"summary\": \"一两句话总结\", \"issues\": [{\"severity\": \"high|medium|low\", \"category\": \"correctness|security|performance|maintainability\", \"file\": \"路径\", \"line\": 行号, \"description\": \"问题\", \"suggestion\": \"建议\"}], \"strengths\": [\"做得好的地方\"], \"recommendation\": \"approve|request_changes\"}

verdict 规则：有任何 high severity 问题则为 fail，否则为 pass。

---

完成所有五步后，输出 PIPELINE_COMPLETE。"
fi

log_info "启动 Claude 自主执行..."

claude \
        --dangerously-skip-permissions \
        --print \
        --verbose \
        <<< "${PROMPT}"
if [ $? -ne 0 ]; then
    log_error "Claude 执行超时或失败"
    exit 2
fi

log_success "Claude 自主执行完成"

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

log_section "流水线完成 ✓"
log_info "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
exit 0
