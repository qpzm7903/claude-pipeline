#!/usr/bin/env bash
# entrypoint.sh - Claude Pipeline Agent
#
# bash 只做三件事：
#   1. 克隆仓库 + 创建分支
#   2. 启动 Claude（完全自主执行 TDD 流水线）
#   3. 提交代码 + 推送 + 创建 PR
#
# 所有语言/框架/工具的决策全部由 Claude 自主完成，bash 不干预。

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}════════════════════════════════════════\n  $*\n════════════════════════════════════════${NC}\n"; }

WORKSPACE="/workspace"
AGENT_TIMEOUT="${AGENT_TIMEOUT:-1800}"   # Claude 自主执行总超时 30 分钟

log_section "Claude Pipeline Agent 启动"
log_info "Task ID:  ${TASK_ID}"
log_info "Task:     ${TASK_TITLE}"
log_info "Branch:   ${BRANCH_NAME}"
log_info "Model:    ${ANTHROPIC_MODEL:-(default)}"
log_info "Base URL: ${ANTHROPIC_BASE_URL:-(official)}"

# ── 步骤 0: 环境检查 ────────────────────────────────────────────────

log_section "步骤 0: 环境检查"

[ -z "${ANTHROPIC_API_KEY:-}" ] && { log_error "ANTHROPIC_API_KEY 未设置"; exit 1; }
command -v claude &>/dev/null || { log_error "claude CLI 未安装"; exit 1; }
log_success "环境检查通过"

# ── 步骤 1: 克隆仓库 ────────────────────────────────────────────────

log_section "步骤 1: 克隆仓库"

AUTH_URL="${REPO_URL}"
[ -n "${GIT_TOKEN:-}" ] && AUTH_URL="${REPO_URL/https:\/\//https://x-access-token:${GIT_TOKEN}@}"

git clone --depth=20 "${AUTH_URL}" "${WORKSPACE}"
cd "${WORKSPACE}"
git config user.name  "${GIT_AUTHOR_NAME:-Claude Pipeline Bot}"
git config user.email "${GIT_AUTHOR_EMAIL:-pipeline@claude.ai}"
git checkout -b "${BRANCH_NAME}"
log_success "克隆完成，分支: ${BRANCH_NAME}"

# ── 步骤 2: Claude 自主执行（TDD + 实现 + 审查）─────────────────────

log_section "步骤 2: Claude 自主执行 TDD 流水线"

# 读取任务信息（从 TASK_JSON 中提取）
TASK_DESCRIPTION=$(python3 -c "import json,os; d=json.loads(os.environ['TASK_JSON']); print(d.get('description',''))")
SPEC_CONTENT=$(python3 -c "import json,os; d=json.loads(os.environ['TASK_JSON']); print(d.get('spec_content',''))")

PROMPT="你是一名全栈工程师，在以下仓库中独立完成一个开发任务。

## 任务
${TASK_DESCRIPTION}

## 需求规格（SPEC）
${SPEC_CONTENT}

## 执行要求

请严格按照 TDD 流程完成：

### 阶段 1 - 写测试（先行）
- 根据 SPEC 编写完整测试，覆盖正常流程、边界条件、错误情况
- 测试此时应当失败（Red 阶段）
- 根据项目语言自动选择测试框架（Rust 用 #[test]，Python 用 pytest，Node 用 jest 等）

### 阶段 2 - 实现代码（让测试通过）
- 如果运行测试需要先安装依赖/工具链，**自行安装**（如 curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 安装 Rust）
- 实现代码直到所有测试通过（Green 阶段）
- 禁止修改测试文件

### 阶段 3 - 审查（输出报告）
- 审查代码质量、安全性、可维护性
- 将审查结果写入文件 review_result.json：
  {\"verdict\": \"pass|fail\", \"score\": 0-100, \"summary\": \"...\", \"issues\": [], \"recommendation\": \"approve|request_changes\"}

完成后输出 PIPELINE_COMPLETE 标记。"

log_info "启动 Claude 自主执行（超时: ${AGENT_TIMEOUT}s）..."

if ! timeout "${AGENT_TIMEOUT}" claude \
        --dangerously-skip-permissions \
        --print \
        <<< "${PROMPT}"; then
    log_error "Claude 执行超时或失败"
    exit 2
fi

log_success "Claude 自主执行完成"

# ── 步骤 3: 提交 + 推送 + PR ────────────────────────────────────────

log_section "步骤 3: 提交代码"

cd "${WORKSPACE}"
git add -A

if git diff --cached --quiet; then
    log_warning "无变更可提交"
else
    REVIEW_VERDICT=$(python3 -c "
import json, pathlib
p = pathlib.Path('review_result.json')
print(json.loads(p.read_text()).get('verdict','unknown') if p.exists() else 'no-review')
" 2>/dev/null || echo "unknown")

    git commit -m "feat(task-${TASK_ID}): ${TASK_TITLE}

Automated by Claude Pipeline (TDD)
Review verdict: ${REVIEW_VERDICT}
Task-Id: ${TASK_ID}"

    log_success "代码已提交"

    if [ -n "${GIT_TOKEN:-}" ]; then
        git push origin "${BRANCH_NAME}"
        log_success "已推送: ${BRANCH_NAME}"
        python3 /agent/create_pr.py
    else
        log_warning "GIT_TOKEN 未设置，跳过推送"
    fi
fi

log_section "流水线完成 ✓"
log_info "Task: ${TASK_ID} | Branch: ${BRANCH_NAME}"
exit 0
