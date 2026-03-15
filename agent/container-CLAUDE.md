# Pipeline 开发规则（全局强制）

## 提交规则（最重要）

每次实施完成后，**必须**在输出任何终止信号（`PIPELINE_COMPLETE` / `REVIEW_COMPLETE` 等）之前执行提交：

1. 运行测试验证代码正确
2. `git add -A`
3. `git commit -m "<type>(<scope>): <描述>"`

**禁止在未 commit 的情况下输出 `PIPELINE_COMPLETE`。**

若跳过此步骤，pipeline 会生成一个低质量的 fallback commit，并触发 CI 失败。

## Commit 格式

遵循 Conventional Commits：

- `feat` / `fix` / `test` / `chore` / `docs` / `refactor`
- 描述具体变更内容，不能只写 "changes" 或 "update"
- 示例：`feat(auth): add JWT refresh token support`

## 测试验证

commit 前必须先运行测试：

- **Rust 项目**：`cargo test --no-default-features`（禁用 xcap/screenshot feature，避免编译失败）
- **Node 项目**：`npm test` 或 `npx vitest run`
- 测试失败时修复测试，不能跳过或用 mock 绕过根本原因

## CI 失败处理

看到 `pipeline-ci-failure` issue 时：

1. `gh run view <run-id> --log-failed` 查看失败日志
2. 分析根本原因（不是症状）
3. 修复代码
4. 本地测试验证通过：`cargo test --no-default-features`
5. `git add -A && git commit -m "fix(...): ..."`
6. close issue（`gh issue close <number>`）

## 禁止行为

- 禁止在 commit 前输出 `PIPELINE_COMPLETE`
- 禁止用空提交（`--allow-empty`）绕过提交要求
- 禁止 `git push`（由 entrypoint.sh 统一处理）
- 禁止用 mock 或 `#[cfg(test)]` 跳过真实逻辑来通过测试
