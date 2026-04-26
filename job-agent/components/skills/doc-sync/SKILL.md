---
name: doc-sync
description: Synchronize project documentation after code changes. Use when asked to "update docs", "sync README", "update plan.md", or after completing a development task. Only modifies documentation files, never touches source code.
---

# Doc Sync — 文档同步

任务执行完成后，同步更新项目文档，确保文档与代码状态一致。

## 决策树

```
检测本次变更 → git diff --stat
    ├─ 有新增/修改的测试文件 → 更新 plan.md 进度
    ├─ 有新增模块/类 → 更新 README.md 结构说明
    ├─ 有 API 变更 → 更新 API 文档（如有）
    └─ 无实质变更 → 仅标注"本轮无变更"
```

## 允许修改的文件

| 文件 | 更新内容 |
|------|---------|
| `plan.md` | 标记已完成任务、更新进度百分比 |
| `README.md` | 项目结构、依赖、快速开始指南 |
| `CHANGELOG.md` | 按 Keep a Changelog 格式追加 |
| `docs/**` | 项目文档目录下的文件 |
| `issues.md` | 已知问题和待解决项 |

## 执行步骤

### 1. 收集变更信息

```bash
# 本次变更的文件列表
git diff --stat HEAD~1..HEAD 2>/dev/null || git diff --stat

# 新增的测试文件
git diff --name-only --diff-filter=A HEAD~1..HEAD 2>/dev/null | grep -E 'Test\.java$'
```

### 2. 更新文档

- **plan.md**: 把已完成方法的状态从 `[ ]` 改为 `[x]`
- **README.md**: 如有结构性变化，更新相关章节
- **CHANGELOG.md**: 追加 `[Unreleased]` 条目

### 3. 提交文档变更

```bash
git add plan.md README.md CHANGELOG.md docs/ 2>/dev/null
git commit -m "docs: 同步文档 — $(date +%Y-%m-%d)" 2>/dev/null || true
```

## 约束

- 只描述**本次任务真正发生的修改**
- **不要编造**覆盖率数据或测试结果
- **不得修改**任何 `.java`、`.xml`、`.properties` 文件
- 如果无实质变更，不要强行更新文档
