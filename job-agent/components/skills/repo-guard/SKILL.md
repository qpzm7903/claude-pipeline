---
name: repo-guard
description: Verify repository safety boundaries before any task execution. Use when starting a pipeline task, before making code changes, or when asked to "check repo safety" or "verify workspace". Scans for protected file violations, validates git configuration, and ensures workspace cleanliness.
---

# Repo Guard — 仓库安全边界守卫

在执行任何实质性任务之前，先运行此 Skill 确保工作区状态安全。

## 检查流程

```
启动 → 受保护文件检查
         ├─ 发现受保护文件在暂存区 → ❌ 报告并阻止
         └─ 未发现 → Git 配置检查
                      ├─ user.name/email 未设置 → ⚠️ 警告
                      └─ 已设置 → 工作区干净度检查
                                   ├─ 有敏感文件 → ❌ 报告
                                   └─ 干净 → ✅ 通过
```

## 受保护文件列表

以下文件/路径**严禁修改**，如果发现这些文件出现在 `git diff --cached` 中，必须立即报告：

- `prompt.md` — 任务指令文件
- `.github/` — CI/CD 配置
- `Dockerfile*` — 容器构建配置
- `.env*` — 环境变量文件
- `*.key`, `*.pem`, `*.p12`, `*.jks` — 密钥和证书
- `.git-credentials` — Git 凭证

## 执行步骤

### 1. 扫描受保护文件

```bash
# 检查暂存区
git diff --cached --name-only 2>/dev/null | grep -E '(prompt\.md|\.github/|Dockerfile|\.env|\.key$|\.pem$|\.p12$|\.jks$|\.git-credentials)'

# 检查未跟踪的敏感文件
find . -maxdepth 3 -name '*.key' -o -name '*.pem' -o -name '*.p12' -o -name '.env.local' 2>/dev/null | grep -v node_modules | grep -v .git
```

### 2. 验证 Git 配置

```bash
git config user.name
git config user.email
git rev-parse --abbrev-ref HEAD
```

### 3. 输出结构化结果

```json
{
  "status": "pass",
  "checks": {
    "protected_files": "pass",
    "git_config": "pass",
    "workspace_clean": "pass"
  },
  "details": "所有检查通过，可以开始任务"
}
```

## 注意事项

- 如果任何检查失败，**不要继续执行后续任务**
- 仅做只读检查，不修改任何文件
- 检查结果写入标准输出，不写入文件
