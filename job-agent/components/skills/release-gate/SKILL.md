---
name: release-gate
description: Make publish/no-publish decisions based on build results, test outcomes, and code review status. Use when asked "can we publish", "is it safe to release", or at the end of a pipeline run. Outputs a structured JSON decision — does NOT execute any git operations.
---

# Release Gate — 发布决策

你不执行发布，**只输出决策**。根据当前质量门状态判断是否允许提交和推送。

## 决策树

```
收集信号 → 评估质量门
    ├─ 构建失败 (mvn test exit ≠ 0) → ❌ 阻断
    ├─ 有编译错误 → ❌ 阻断
    ├─ 修改了受保护文件 → ❌ 阻断
    ├─ 测试通过率 < 100% → ❌ 阻断
    ├─ 覆盖率 < 60% → ⚠️ 警告（不阻断）
    └─ 全部通过 → ✅ 允许发布
```

## 信号收集

### 1. 构建状态

```bash
# 检查最近的构建结果
mvn test -pl {module} -q 2>&1 | tail -20
echo "Exit code: $?"
```

### 2. 变更检查

```bash
# 是否修改了受保护文件
git diff --name-only HEAD~1..HEAD | grep -E '(prompt\.md|\.github/|Dockerfile|\.env)'
```

### 3. 覆盖率（如有 JaCoCo）

```bash
# 查找覆盖率报告
find . -path '*/jacoco/jacoco.xml' -exec grep -o 'covered="[0-9]*"' {} \; | head -5
```

## 输出格式

**必须**输出以下 JSON 结构：

```json
{
  "publish_allowed": true,
  "confidence": "high",
  "gates": {
    "build": { "status": "pass", "detail": "mvn test exit 0" },
    "tests": { "status": "pass", "detail": "47/47 passed" },
    "protected_files": { "status": "pass", "detail": "no violations" },
    "coverage": { "status": "warn", "detail": "58% (threshold: 60%)" }
  },
  "recommended_action": "commit_and_push",
  "recommended_version_bump": "PATCH",
  "warnings": ["覆盖率略低于 60% 门槛"],
  "blockers": []
}
```

## 约束

- **只做判断**，不执行任何 `git commit`、`git push`、`git tag` 操作
- **不修改**任何文件
- 如果无法获取某个信号，标注为 `"status": "unknown"` 而非假设通过
