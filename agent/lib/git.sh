#!/usr/bin/env bash
# lib/git.sh - Git 仓库克隆与编译缓存
#
# 依赖变量: REPO_URL, GIT_TOKEN (optional), GIT_AUTHOR_NAME (optional),
#           GIT_AUTHOR_EMAIL (optional), WORKSPACE
# 依赖函数: log_info, log_success, log_warning, log_error, log_section
# 导出变量: BEFORE_COMMIT, CARGO_TARGET_DIR (optional)
# 提供函数: clone_repo, setup_build_cache

clone_repo() {
  log_section "步骤 1: 克隆仓库"

  local AUTH_URL="${REPO_URL}"
  [ -n "${GIT_TOKEN:-}" ] && AUTH_URL="${REPO_URL/https:\/\//https://x-access-token:${GIT_TOKEN}@}"

  local CLONE_OK=false
  local _clone_attempt
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
}

setup_build_cache() {
  local _BUILD_CACHE="/home/pipeline/.build-cache"
  if [ -d "${_BUILD_CACHE}" ] && [ -w "${_BUILD_CACHE}" ]; then
    local _REPO_SLUG
    _REPO_SLUG=$(echo "${REPO_URL}" | sed -E 's|.*github\.com[/:]||; s|\.git$||; s|/|-|g' | tr '[:upper:]' '[:lower:]')
    export CARGO_TARGET_DIR="${_BUILD_CACHE}/${_REPO_SLUG}"
    mkdir -p "${CARGO_TARGET_DIR}" 2>/dev/null || true
    # 清理 7 天未使用的缓存（其他 repo 的旧缓存）
    find "${_BUILD_CACHE}" -maxdepth 1 -mindepth 1 -type d -not -name "${_REPO_SLUG}" \
      -mtime +7 -exec rm -rf {} \; 2>/dev/null || true
    log_info "Build cache: ${CARGO_TARGET_DIR}"
  fi
}
