#!/usr/bin/env bash
# pack-local.sh - 打包本地运行版（不含 Docker / K8s 相关文件）
#
# 用法:
#   ./pack-local.sh              # 生成 claude-pipeline-local-<version>.zip
#   ./pack-local.sh v1.2.3       # 指定版本号
#
# 输出: dist/claude-pipeline-local-<version>.zip

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:-$(git -C "${SCRIPT_DIR}" describe --tags --always 2>/dev/null || date +%Y%m%d)}"
DIST_DIR="${SCRIPT_DIR}/dist"
PACK_NAME="claude-pipeline-local-${VERSION}"
PACK_DIR="${DIST_DIR}/${PACK_NAME}"

# 颜色
BLUE='\033[0;34m'; GREEN='\033[0;32m'; NC='\033[0m'

echo -e "${BLUE}[INFO]${NC}  打包本地运行版: ${PACK_NAME}"

# ── 清理 & 创建临时目录 ────────────────────────────────────────────
rm -rf "${PACK_DIR}"
mkdir -p "${PACK_DIR}/agent/lib" "${PACK_DIR}/config"

# ── 复制文件 ────────────────────────────────────────────────────────
# 启动器
cp "${SCRIPT_DIR}/run-local.sh" "${PACK_DIR}/"
chmod +x "${PACK_DIR}/run-local.sh"

# Agent 核心
cp "${SCRIPT_DIR}/agent/entrypoint.sh" "${PACK_DIR}/agent/"
cp "${SCRIPT_DIR}/agent/default-prompt.txt" "${PACK_DIR}/agent/"
cp "${SCRIPT_DIR}/agent/auto-iterate-prompt.txt" "${PACK_DIR}/agent/"
cp "${SCRIPT_DIR}/agent/repo-prompt-driven.txt" "${PACK_DIR}/agent/"
cp "${SCRIPT_DIR}/agent/lib/log.sh" "${PACK_DIR}/agent/lib/"
cp "${SCRIPT_DIR}/agent/lib/git.sh" "${PACK_DIR}/agent/lib/"
cp "${SCRIPT_DIR}/agent/lib/run.sh" "${PACK_DIR}/agent/lib/"
cp "${SCRIPT_DIR}/agent/lib/fmt_stream.py" "${PACK_DIR}/agent/lib/"
chmod +x "${PACK_DIR}/agent/entrypoint.sh" "${PACK_DIR}/agent/lib/"*.sh

# 配置模板
if [ -f "${SCRIPT_DIR}/config/config.yaml" ]; then
  cp "${SCRIPT_DIR}/config/config.yaml" "${PACK_DIR}/config/"
fi

# .env 模板（不复制实际密钥）
if [ -f "${SCRIPT_DIR}/.env.example" ]; then
  cp "${SCRIPT_DIR}/.env.example" "${PACK_DIR}/.env.example"
fi

# README
cat > "${PACK_DIR}/README.md" << 'README_EOF'
# Claude Pipeline Agent — 本地运行版

## 前置依赖

| 依赖 | 必需？ | 说明 |
|------|--------|------|
| bash | ✅ | 系统自带 |
| git | ✅ | 代码克隆与提交 |
| claude CLI | ✅ | 可通过 `CLAUDE_CMD` 指定路径 |
| python3 | ⚠️ 推荐 | stream 格式化输出 |
| gh | ❌ 可选 | CI 检查 / Issue 管理 |

## 快速开始

1. 复制 `.env.example` 为 `.env` 并填写配置：

```bash
cp .env.example .env
# 编辑 .env，填入 ANTHROPIC_API_KEY 等
```

2. 启动：

```bash
# 方式 1: 指定 repo URL（自动克隆）
./run-local.sh https://github.com/user/repo

# 方式 2: 在已有仓库中运行
cd /path/to/your/repo
REPO_URL=https://github.com/user/repo /path/to/run-local.sh
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ANTHROPIC_API_KEY` | （必填） | API 密钥 |
| `ANTHROPIC_MODEL` | claude-opus-4-5-20251001 | 模型 |
| `ANTHROPIC_BASE_URL` | （官方） | API 代理地址 |
| `CLAUDE_CMD` | claude | claude 命令路径 |
| `GIT_TOKEN` | （可选） | 私有仓库访问令牌 |
| `WORKSPACE` | $PWD | 工作目录 |
| `PIPELINE_MODE` | bmad | 执行模式: bmad / autoresearch / custom |
| `PIPELINE_LOG_DIR` | $HOME/.pipeline/logs | 日志目录 |
| `BUILD_CACHE_DIR` | $HOME/.pipeline/build-cache | 编译缓存目录 |
README_EOF

# ── 打 zip 包 ──────────────────────────────────────────────────────
cd "${DIST_DIR}"
rm -f "${PACK_NAME}.zip"
zip -r "${PACK_NAME}.zip" "${PACK_NAME}/"

# ── 打印结果 ────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}✅ 打包完成:${NC} ${DIST_DIR}/${PACK_NAME}.zip"
echo ""
echo "包内容:"
zipinfo -1 "${PACK_NAME}.zip" | sed 's/^/  /'
echo ""
SIZE=$(du -sh "${PACK_NAME}.zip" | cut -f1)
echo -e "${BLUE}大小:${NC} ${SIZE}"

# 清理临时目录
rm -rf "${PACK_DIR}"
