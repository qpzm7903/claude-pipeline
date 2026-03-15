#!/usr/bin/env bash
# run.sh - 极简启动脚本，替代 orchestrator
#
# 用法:
#   ./run.sh https://github.com/user/repo   # 为单个 repo 启动容器
#   ./run.sh                                 # 批量启动 repos.yaml 中所有 enabled repo
#
# 环境变量（均可通过 .env 或 shell export 传入）：
#   ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN
#   ANTHROPIC_MODEL / CLAUDE_MODEL
#   GIT_TOKEN / GITHUB_TOKEN
#   ANTHROPIC_BASE_URL（非空才传入容器）
#   DOCKER_IMAGE（默认 claude-pipeline-agent:latest）

set -euo pipefail

IMAGE="${DOCKER_IMAGE:-claude-pipeline-agent:latest}"
API_KEY="${ANTHROPIC_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}"
MODEL="${ANTHROPIC_MODEL:-${CLAUDE_MODEL:-claude-opus-4-5-20251001}}"
GH="${GIT_TOKEN:-${GITHUB_TOKEN:-}}"

[ -z "$API_KEY" ] && { echo "[ERROR] ANTHROPIC_API_KEY 或 ANTHROPIC_AUTH_TOKEN 未设置"; exit 1; }

# 从 config.yaml 提取默认值
if command -v python3 &>/dev/null && [ -f "config/config.yaml" ]; then
  GIT_NAME=$(python3 -c "import yaml; print(yaml.safe_load(open('config/config.yaml')).get('git', {}).get('author_name', 'Claude Pipeline Bot'))" 2>/dev/null || echo "Claude Pipeline Bot")
  GIT_EMAIL=$(python3 -c "import yaml; print(yaml.safe_load(open('config/config.yaml')).get('git', {}).get('author_email', 'pipeline@claude.ai'))" 2>/dev/null || echo "pipeline@claude.ai")
else
  GIT_NAME="Claude Pipeline Bot"
  GIT_EMAIL="pipeline@claude.ai"
fi

GIT_NAME="${GIT_AUTHOR_NAME:-$GIT_NAME}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-$GIT_EMAIL}"

run_container() {
  local repo_url="$1"
  local args=(
    -d -m 4g --cpus 1
    --label claude-pipeline=true
    -v cargo-registry-cache:/home/pipeline/.cargo/registry
    -e REPO_URL="$repo_url"
    -e ANTHROPIC_API_KEY="$API_KEY"
    -e ANTHROPIC_AUTH_TOKEN="$API_KEY"
    -e ANTHROPIC_MODEL="$MODEL"
    -e CLAUDE_MODEL="$MODEL"
    -e GIT_TOKEN="$GH"
    -e GITHUB_TOKEN="$GH"
    -e GH_TOKEN="$GH"
    -e GIT_AUTHOR_NAME="$GIT_NAME"
    -e GIT_AUTHOR_EMAIL="$GIT_EMAIL"
  )
  [ -n "${ANTHROPIC_BASE_URL:-}" ] && args+=(-e ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL")

  local cid
  cid=$(docker run "${args[@]}" "$IMAGE")
  echo "[OK] 容器已启动: ${cid:0:12}  repo=$repo_url"
}

if [ -n "${1:-}" ]; then
  run_container "$1"
else
  python3 -c "
import yaml, subprocess, os, sys
cfg = yaml.safe_load(open('config/repos.yaml'))
repos = [r for r in cfg.get('repos', []) if r.get('enabled', True)]
if not repos:
    print('[WARN] repos.yaml 中没有 enabled 的 repo')
    sys.exit(0)
for r in repos:
    subprocess.run(['bash', sys.argv[0], r['url']], env=os.environ, check=True)
" "$0"
fi
