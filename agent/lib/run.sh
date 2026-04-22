#!/usr/bin/env bash
# lib/run.sh - Claude 执行引擎
#
# 依赖变量: PROMPT, _ROUND_TIMEOUT, _LOG_FILE, BEFORE_COMMIT,
#           _SCRIPT_DIR (指向 agent/ 目录)
# 依赖函数: log_info, log_success, log_warning, log_error, log_section
# 提供函数: _fmt_stream, _run_claude, run_single, run_iterate

_fmt_stream() {
  python3 -u "${_SCRIPT_DIR}/lib/fmt_stream.py" 2>&1 | while IFS= read -r _fmtline; do
    echo "$_fmtline"
    echo "$_fmtline" >> "${_LOG_FILE:-/dev/null}" 2>/dev/null || true
  done
}

_run_claude() {
  timeout "$_ROUND_TIMEOUT" \
    "${CLAUDE_CMD:-claude}" \
      --dangerously-skip-permissions \
      --print \
      --verbose \
      --output-format stream-json \
      <<< "${PROMPT}" 2>&1 | _fmt_stream
  local _rc="${PIPESTATUS[0]}"
  if [ "$_rc" -eq 124 ]; then
    log_warning "Claude 执行超时（${_ROUND_TIMEOUT}s），强制结束本轮"
  fi
  return "$_rc"
}

run_single() {
  log_info "启动 Claude 自主执行..."

  local _EXIT=0
  _run_claude || _EXIT=$?
  if [ $_EXIT -ne 0 ]; then
      log_error "Claude 执行超时或失败"
      exit 2
  fi

  log_success "Claude 自主执行完成"

  local AFTER_COMMIT
  AFTER_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$BEFORE_COMMIT" ] && [ "$BEFORE_COMMIT" = "$AFTER_COMMIT" ]; then
      log_error "Pipeline 失败: 代码仓库没有任何新的 commit (避免 Completed 状态虚假成功)"
      exit 3
  fi
}

run_iterate() {
  local _ITER=0
  local _MAX_ITER="${MAX_ITERATIONS:-0}"       # 0 = 无限
  local _COOLDOWN="${ITER_COOLDOWN:-10}"       # 迭代间隔秒
  local _CONSECUTIVE_FAILS=0
  local _CONSECUTIVE_NOCHANGE=0
  local _MAX_NOCHANGE="${MAX_NOCHANGE:-3}"     # 连续无变更 N 次则退出

  log_info "模式: ${PIPELINE_MODE:-iterate} (max=${_MAX_ITER:-∞}, cooldown=${_COOLDOWN}s, timeout=${_ROUND_TIMEOUT}s, max_nochange=${_MAX_NOCHANGE})"

  while true; do
    _ITER=$((_ITER + 1))
    log_section "自主迭代 #${_ITER}"

    local _BEFORE
    _BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "")

    # 拉取远程最新代码（可能有其他 agent 的推送）
    git pull --rebase 2>/dev/null || true

    local _EXIT=0
    _run_claude || _EXIT=$?

    local _AFTER
    _AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")

    if [ "$_BEFORE" != "$_AFTER" ]; then
      # 检查是否只有进度文件变更（非实质性工作）
      local _changed_files
      _changed_files=$(git diff --name-only "$_BEFORE" "$_AFTER" 2>/dev/null || echo "")
      local _has_real_change=false
      while IFS= read -r _f; do
        case "$_f" in
          .auto-progress.md|.claude/*) ;;  # 忽略进度/元数据文件
          ?*) _has_real_change=true; break ;;
        esac
      done <<< "$_changed_files"

      if [ "$_has_real_change" = "true" ]; then
        log_success "迭代 #${_ITER}: 产生新 commit"
        git push 2>/dev/null || log_warning "push 失败，下轮重试"
        _CONSECUTIVE_FAILS=0
        _CONSECUTIVE_NOCHANGE=0
      else
        _CONSECUTIVE_NOCHANGE=$((_CONSECUTIVE_NOCHANGE + 1))
        log_warning "迭代 #${_ITER}: 仅进度文件变更，视为无实质工作 (连续=${_CONSECUTIVE_NOCHANGE}/${_MAX_NOCHANGE})"
        # 仍然推送进度文件，但不重置 nochange 计数
        git push 2>/dev/null || true
      fi
    elif [ $_EXIT -ne 0 ] && [ $_EXIT -ne 124 ]; then
      _CONSECUTIVE_FAILS=$((_CONSECUTIVE_FAILS + 1))
      log_warning "迭代 #${_ITER}: Claude 异常退出 (code=$_EXIT, 连续失败=${_CONSECUTIVE_FAILS})"
    else
      _CONSECUTIVE_NOCHANGE=$((_CONSECUTIVE_NOCHANGE + 1))
      log_info "迭代 #${_ITER}: 无变更 (连续=${_CONSECUTIVE_NOCHANGE}/${_MAX_NOCHANGE})"
      _CONSECUTIVE_FAILS=0
    fi

    # 连续失败 5 次，认为存在系统性问题，退出
    if [ $_CONSECUTIVE_FAILS -ge 5 ]; then
      log_error "连续 ${_CONSECUTIVE_FAILS} 次失败，退出"
      exit 2
    fi

    # 连续无变更达到上限，项目已成熟，退出
    if [ $_CONSECUTIVE_NOCHANGE -ge "$_MAX_NOCHANGE" ]; then
      log_info "连续 ${_CONSECUTIVE_NOCHANGE} 轮无变更，项目已趋于成熟，退出"
      break
    fi

    # 检查是否达到最大迭代次数
    if [ "$_MAX_ITER" -gt 0 ] && [ "$_ITER" -ge "$_MAX_ITER" ]; then
      log_info "达到最大迭代次数 $_MAX_ITER，退出"
      break
    fi

    sleep "$_COOLDOWN"
  done
}
