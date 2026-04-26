# job-demo · 代码重构任务

## 项目上下文

仓库：https://github.com/qpzm7903/job-demo
当前状态：v0.5.x（OAuth2 授权服务器，含完整测试基线）。

## 重构不变量（红线，不可越过）

- 所有现有测试**必须全部通过**（重构前后）
- Public API 不变：REST 端点 / HTTP 方法 / 请求参数 / 响应结构 / 异常类型 一律不变
- 功能行为不变：`/oauth2/token`、`/oauth2/jwks`、`/hello`、`authorization_code` 流 全部照常工作
- **每轮只做 1 个重构手法**

## 候选异味（按出现概率排序）

1. 过长方法（> 40 行）
2. 过大类（> 300 行 或 > 10 方法）
3. 重复代码块（同一逻辑出现 3+ 处）
4. 过深嵌套（> 3 层 if / try）
5. 命名不清（doThing / handle / process / data / info）

## 每轮严格 5 步

### 1. Map（绘制地图）
扫 `src/main/java`，挑出**最严重**的一个异味。命令示例：
```
find src/main/java -name "*.java" -exec wc -l {} + | sort -rn | head -10
```
输出选中的文件 + 行号。

### 2. Plan（决策块）
```
## 决策: 重构 <目标方法或类>
- 异味: <具体描述，引用代码片段>
- 手法: Extract Method / Extract Class / Rename / Inline / Move / Remove Duplication 中的 1 个
- 影响: <涉及的文件清单>
- 风险: <可能影响的测试或行为>
```

### 3. Baseline
```
mvn test > /tmp/baseline.log 2>&1; echo "EXIT=$?" >> /tmp/baseline.log; tail -5 /tmp/baseline.log
```
EXIT≠0 → 本轮目标改为"修复基线"，用 `fix(test): ...` 提交，**不**重构。

### 4. Execute
- 只动源码 + 测试，**禁止**改 `pom.xml` / `plan.md` / `README.md`（不升版本）
- 改动处加 1~2 行简体中文注释解释"为什么这样重构"

### 5. Verify + Commit
```
mvn test > /tmp/after.log 2>&1; echo "EXIT=$?" >> /tmp/after.log; tail -10 /tmp/after.log
```
- EXIT=0 → `git add + commit + push`，commit `refactor(<范围>): <描述>` 简体中文
- EXIT≠0 → `git checkout -- .` 回滚，本轮以 `docs(refactor): 重构尝试说明` 提交一份 200 字内的失败原因

## Commit 规范（红线）

- `refactor(<范围>): <描述>` 简体中文
- **严禁** AI 署名（`Co-Authored-By: Claude` / `Written by AI`）
- 不附 `Signed-off-by`
- git 用户：默认（已配置为 qpzm7903）

## 禁止事项

- 禁止新增功能
- 禁止升 `pom.xml` 版本号
- 禁止改 API（路径、方法、参数、返回结构）
- 禁止"大重构"（涉及 3+ 文件结构变更）
- 禁止改动 Spring Authorization Server 的 bean 配置（容易破坏授权流）

## 收敛

如果找不到值得重构的地方（代码已经够干净）→ 提交 `docs(refactor): 代码质量评估说明`，附 `docs/refactor-review-$(date +%Y%m%d).md`（200 字内），本轮结束，无需继续迭代。
