#!/usr/bin/env bash
# entrypoint.sh - Claude Pipeline Agent
#
# 流程编排入口，业务逻辑委托给 lib/ 下的模块：
#   lib/log.sh         — 日志函数
#   lib/git.sh         — 仓库克隆、编译缓存
#   lib/fmt_stream.py  — stream-json 格式化
#   lib/run.sh         — Claude 执行引擎（single / iterate）

set -euo pipefail

# ── 定位脚本目录 ────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 环境配置 ────────────────────────────────────────────────────────
export ENABLE_LSP_TOOL=1
WORKSPACE="${WORKSPACE:-$(pwd)}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"

# ── 加载模块 ────────────────────────────────────────────────────────
source "${_SCRIPT_DIR}/lib/log.sh"
source "${_SCRIPT_DIR}/lib/git.sh"

# ── 启动信息 ────────────────────────────────────────────────────────
log_section "Claude Pipeline Agent 启动"
log_info "Repo:     ${REPO_URL}"
log_info "Model:    ${ANTHROPIC_MODEL:-(default)}"
log_info "Base URL: ${ANTHROPIC_BASE_URL:-(official)}"
log_info "Mode:     ${PIPELINE_MODE:-(default)}"
log_info "Exec:     ${EXEC_MODE:-(auto)}"
log_info "Claude:   ${CLAUDE_CMD}"

# ── 步骤 0: 环境检查 ────────────────────────────────────────────────
log_section "步骤 0: 环境检查"

[ -z "${ANTHROPIC_API_KEY:-}" ] && { log_error "ANTHROPIC_API_KEY 未设置"; exit 1; }
[ -z "${REPO_URL:-}" ]          && { log_error "REPO_URL 未设置"; exit 1; }
command -v "${CLAUDE_CMD}" &>/dev/null || { log_error "claude CLI 未找到: ${CLAUDE_CMD}（可通过 CLAUDE_CMD 环境变量指定路径）"; exit 1; }

log_success "环境检查通过"

# ── 步骤 1: 克隆仓库 + 编译缓存 ────────────────────────────────────
clone_repo
setup_build_cache

# ── 步骤 2: 模式选择与 Claude 执行 ─────────────────────────────────
log_section "步骤 2: Claude 自主执行"

# ── 模式选择（PIPELINE_MODE） ─────────────────────────────────────────
#
#  模式 1: bmad         — BMAD 工作流（默认），使用内置 default-prompt.txt
#  模式 2: autoresearch — 自主迭代研究，使用内置 auto-iterate-prompt.txt + 外层循环
#  模式 3: custom       — 用户自定义 prompt（通过 CLAUDE_PROMPT 或 CLAUDE_PROMPT_FILE 传入）
#

# 向后兼容：AUTO_ITERATE=true 等同于 PIPELINE_MODE=autoresearch
if [ -z "${PIPELINE_MODE:-}" ] && [ "${AUTO_ITERATE:-false}" = "true" ]; then
  PIPELINE_MODE="autoresearch"
  log_warning "AUTO_ITERATE 已废弃，请改用 PIPELINE_MODE=autoresearch"
fi

PIPELINE_MODE="${PIPELINE_MODE:-bmad}"

case "${PIPELINE_MODE}" in
  bmad)
    if [ ! -f "${_SCRIPT_DIR}/default-prompt.txt" ]; then
      log_error "BMAD 模式需要 ${_SCRIPT_DIR}/default-prompt.txt，但文件不存在"
      exit 1
    fi
    PROMPT=$(cat "${_SCRIPT_DIR}/default-prompt.txt")
    log_info "模式: bmad（BMAD 工作流，iterate 引擎）— Prompt: default-prompt.txt"
    _EXEC_MODE="${EXEC_MODE:-iterate}"
    ;;
  autoresearch)
    if [ ! -f "${_SCRIPT_DIR}/auto-iterate-prompt.txt" ]; then
      log_error "autoresearch 模式需要 ${_SCRIPT_DIR}/auto-iterate-prompt.txt，但文件不存在"
      exit 1
    fi
    PROMPT=$(cat "${_SCRIPT_DIR}/auto-iterate-prompt.txt")
    log_info "模式: autoresearch（自主迭代研究）— Prompt: auto-iterate-prompt.txt"
    _EXEC_MODE="${EXEC_MODE:-iterate}"
    ;;
  custom)
    if [ -n "${CLAUDE_PROMPT_FILE:-}" ]; then
      if [ -f "${CLAUDE_PROMPT_FILE}" ]; then
        PROMPT=$(cat "${CLAUDE_PROMPT_FILE}")
        log_info "模式: custom — 来源: 文件 ${CLAUDE_PROMPT_FILE}"
      else
        log_error "CLAUDE_PROMPT_FILE 指定的文件不存在: ${CLAUDE_PROMPT_FILE}"
        exit 1
      fi
    elif [ -n "${CLAUDE_PROMPT:-}" ]; then
      PROMPT="${CLAUDE_PROMPT}"
      log_info "模式: custom — 来源: 环境变量 CLAUDE_PROMPT (${#PROMPT} 字符)"
    else
      log_error "custom 模式需要设置 CLAUDE_PROMPT_FILE 或 CLAUDE_PROMPT"
      exit 1
    fi
    _EXEC_MODE="${EXEC_MODE:-single}"
    ;;
  *)
    log_error "未知 PIPELINE_MODE: ${PIPELINE_MODE}（可选: bmad, autoresearch, custom）"
    exit 1
    ;;
esac

# ── 执行 Claude ───────────────────────────────────────────────────────
_ROUND_TIMEOUT="${ROUND_TIMEOUT:-1800}"

source "${_SCRIPT_DIR}/lib/run.sh"

if [ "${_EXEC_MODE}" = "iterate" ]; then
  run_iterate
else
  run_single
fi

# ── 完成 ──────────────────────────────────────────────────────────────
log_section "流水线完成 ✓"
log_info "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
exit 0
