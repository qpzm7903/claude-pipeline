# Pipeline 容器规则（全局强制）

## 提交规范

- 完成所有工作后 **必须** 执行 `git add -A && git commit`
- 使用 Conventional Commits 格式：`feat/fix/chore/test/docs/refactor`
- 描述具体变更内容，不能只写 "changes" 或 "update"
- 示例：`feat(auth): add JWT refresh token support`

## 推送与合并规则

- 提交代码后，你**必须**使用 `git push` 将代码推送到远程仓库
- 如果你是在新的分支上工作，请直接使用 `gh pr create` 命令创建 Pull Request

## 禁止行为

- **禁止** `git push --force`
- **禁止** 空提交（`--allow-empty`）

## 测试验证

commit 前必须先运行测试验证代码正确：

- **Rust 项目**：优先 `cargo test`；若含 xcap/screenshot feature 导致编译失败，改用 `cargo test --no-default-features`
- **Node 项目**：`npm test` 或 `npx vitest run`
- 测试失败时修复代码，不跳过或用 mock 绕过根本原因
