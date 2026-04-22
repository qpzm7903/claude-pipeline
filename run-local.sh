#!/usr/bin/env bash
# run-local.sh - 裸机 / VM 直接运行 Agent（不依赖 Docker）
#
# 用法:
#   ./run-local.sh https://github.com/user/repo     # 克隆并执行
#   WORKSPACE=/path/to/repo ./run-local.sh           # 在已有目录中执行（不克隆）
#
# 环境变量（均可通过 .env 或 shell export 传入）：
#   ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN    — API 密钥（必需）
#   ANTHROPIC_MODEL / CLAUDE_MODEL              — 模型选择
#   GIT_TOKEN / GITHUB_TOKEN                    — Git 访问令牌
#   ANTHROPIC_BASE_URL                          — API 代理地址
#   WORKSPACE                                   — 工作目录（默认 $PWD）
#   CLAUDE_CMD                                  — claude 命令路径（默认 claude）
#   PIPELINE_MODE                               — 执行模式: bmad / autoresearch / custom
#   EXEC_MODE                                   — 执行引擎: single / iterate
#   PIPELINE_LOG_DIR                            — 日志目录（默认 $HOME/.pipeline/logs）
#   BUILD_CACHE_DIR                             — 编译缓存目录（默认 $HOME/.pipeline/build-cache）
#
# Prompt 自定义（三选一，优先级从高到低）：
#   CLAUDE_PROMPT_FILE=/path/to/prompt.txt      — 本地 prompt 文件
#   CLAUDE_PROMPT="..."                         — 内联字符串
#   （不设置）                                  — 使用 agent/default-prompt.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 加载 .env ──────────────────────────────────────────────────────
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

# ── 环境变量整理 ────────────────────────────────────────────────────
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_API_KEY}"
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-${CLAUDE_MODEL:-claude-opus-4-5-20251001}}"
export CLAUDE_MODEL="${ANTHROPIC_MODEL}"
export GIT_TOKEN="${GIT_TOKEN:-${GITHUB_TOKEN:-}}"
export GITHUB_TOKEN="${GIT_TOKEN}"
export GH_TOKEN="${GIT_TOKEN}"

# 从 config.yaml 提取默认 git 信息
if command -v python3 &>/dev/null && [ -f "${SCRIPT_DIR}/config/config.yaml" ]; then
  _GIT_NAME=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/config/config.yaml')).get('git', {}).get('author_name', 'Claude Pipeline Bot'))" 2>/dev/null || echo "Claude Pipeline Bot")
  _GIT_EMAIL=$(python3 -c "import yaml; print(yaml.safe_load(open('${SCRIPT_DIR}/config/config.yaml')).get('git', {}).get('author_email', 'pipeline@claude.ai'))" 2>/dev/null || echo "pipeline@claude.ai")
else
  _GIT_NAME="Claude Pipeline Bot"
  _GIT_EMAIL="pipeline@claude.ai"
fi
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-$_GIT_NAME}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-$_GIT_EMAIL}"
export CLAUDE_CMD="${CLAUDE_CMD:-claude}"

# ── 前置检查 ────────────────────────────────────────────────────────
_RED='\033[0;31m'; _GREEN='\033[0;32m'; _YELLOW='\033[1;33m'; _BLUE='\033[0;34m'; _NC='\033[0m'

[ -z "${ANTHROPIC_API_KEY:-}" ] && { echo -e "${_RED}[ERROR]${_NC} ANTHROPIC_API_KEY 或 ANTHROPIC_AUTH_TOKEN 未设置"; exit 1; }

if ! command -v "${CLAUDE_CMD}" &>/dev/null; then
  echo -e "${_RED}[ERROR]${_NC} claude CLI 未找到: ${CLAUDE_CMD}"
  echo -e "         可通过 CLAUDE_CMD 环境变量指定路径，例如: CLAUDE_CMD=/opt/claude/bin/claude"
  exit 1
fi

if ! command -v git &>/dev/null; then
  echo -e "${_RED}[ERROR]${_NC} git 未安装"
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo -e "${_YELLOW}[WARN]${_NC}  gh CLI 未安装，CI 检查 / Issue 管理 / Release 发布功能将不可用"
fi

if ! command -v python3 &>/dev/null; then
  echo -e "${_YELLOW}[WARN]${_NC}  python3 未安装，stream 格式化输出将不可用"
fi

# ── REPO_URL 处理 ──────────────────────────────────────────────────
if [ -n "${1:-}" ]; then
  export REPO_URL="$1"
  # 有 REPO_URL 参数 → 需要克隆，WORKSPACE 设为临时目录
  if [ -z "${WORKSPACE:-}" ]; then
    _REPO_SLUG=$(echo "${REPO_URL}" | sed -E 's|.*[/:]||; s|\.git$||')
    export WORKSPACE="${SCRIPT_DIR}/workspace/${_REPO_SLUG}"
    mkdir -p "${WORKSPACE}"
  fi
elif [ -z "${REPO_URL:-}" ]; then
  # 无参数且无 REPO_URL → 假定在已有仓库中运行
  export WORKSPACE="${WORKSPACE:-$(pwd)}"
  if [ -d "${WORKSPACE}/.git" ]; then
    export REPO_URL=$(git -C "${WORKSPACE}" remote get-url origin 2>/dev/null || echo "local")
  else
    echo -e "${_RED}[ERROR]${_NC} 用法: ./run-local.sh <REPO_URL>  或  WORKSPACE=/path/to/repo REPO_URL=... ./run-local.sh"
    exit 1
  fi
fi

# ── 启动信息 ────────────────────────────────────────────────────────
echo -e "\n${_BLUE}════════════════════════════════════════"
echo -e "  Claude Pipeline Agent（裸机模式）"
echo -e "════════════════════════════════════════${_NC}\n"
echo -e "${_BLUE}[INFO]${_NC}  Repo:      ${REPO_URL}"
echo -e "${_BLUE}[INFO]${_NC}  Workspace: ${WORKSPACE}"
echo -e "${_BLUE}[INFO]${_NC}  Model:     ${ANTHROPIC_MODEL}"
echo -e "${_BLUE}[INFO]${_NC}  Mode:      ${PIPELINE_MODE:-bmad}"
echo -e "${_BLUE}[INFO]${_NC}  Claude:    ${CLAUDE_CMD}"
echo -e "${_BLUE}[INFO]${_NC}  gh CLI:    $(command -v gh &>/dev/null && echo 'available' || echo 'not available')"
echo ""

# ── 执行 entrypoint ────────────────────────────────────────────────
exec bash "${SCRIPT_DIR}/agent/entrypoint.sh"
