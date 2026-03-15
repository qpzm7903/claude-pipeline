# Claude Code 指令

## 项目理解

- 使用 bmad-help 以及阅读 README 理解项目
- 界面需要支持简体中文

## 注意事项

- prompt.md 文件用于下达指令给 Claude Code，**禁止 AI 修改 prompt.md 文件**
- 隐私秘钥等文件禁止上传到 GitHub 仓库
- 授权 Claude Code 自动执行命令和计划，无需批准确认
- 使用 BMAD 工作流开发
- 每次 git 提交文件前确保自验证测试通过，git 提交时不要遗漏文件
- 使用迭代开发模式持续发布新版本
- 检查 GitHub Actions 中最新 workflow 的报错并进行修复
- 仓库的详细介绍持续更新到 README.md 文件

## 代码质量

- **代码质量高于一切**，稳定性、易用性、可用性、用户体验的改进高于新功能的添加
- 每次提交代码前先进行存量代码检视，优化存量代码的架构和功能，移除不需要的功能，确保可以长期演进

## 版本发布要求

- 在创建 Git Tag（例如 `v*`）时自动通过 GitHub Actions 构建项目并发布 GitHub Release
- **构建矩阵（Matrix）**：覆盖三个主要操作系统：
  - Windows (`windows-latest`)
  - Linux (`ubuntu-latest`)
  - macOS (`macos-latest`)
- **文件命名与后缀规范**：生成的构建产物（Artifacts）必须遵循开源社区典型命名规范，包含操作系统和架构信息，使用标准后缀：
  - Windows: `.exe` 或 `.zip`
  - Linux: `.tar.gz` / `.deb` / `.AppImage`
  - macOS: `.dmg` 或 `.tar.gz`（包含 `.app`）
  - 通用: 同时生成 `checksums.txt` 文件包含所有文件的 SHA256 哈希值

## Issue 修复

- 修复打开中的 issue 并关闭，及时发布新版本
- 在 issue 中回复哪个版本已修复并提供新版本下载地址
- 提醒用户进行验证
