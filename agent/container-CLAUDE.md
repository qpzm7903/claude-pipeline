# Pipeline 容器规则（全局强制）

## 提交规范

- **每完成一个独立任务（Task）后立即提交**，不要等整个 Story 全部完成后再提交
  - 例：后端实现完成 + 测试通过 → 立即 commit；前端实现完成 → 再 commit
- 使用 Conventional Commits 格式：`feat/fix/chore/test/docs/refactor`
- 描述具体变更内容，不能只写 "changes" 或 "update"
- 示例：`feat(auth): add JWT refresh token support`

## Context 接近上限时的紧急提交规则

- 当出现 `Prompt is too long` 警告时，**立即停止当前实现工作**
- 执行：`git add -A && git commit -m "wip: [story-id] partial implementation" && git push`
- 即使代码不完整也要提交，避免所有工作丢失
- 提交后可以正常结束，下一个 session 会基于此继续

## 推送与合并规则

- 提交代码后，你**必须**使用 `git push` 将代码推送到远程仓库
- 推送后，你**必须**使用 gh CLI 监控并等待 CI 验证通过。你可以自由决定具体使用哪些命令（不限于 list 或 watch 等）来获取执行结果。如果 CI 失败，必须自主查明原因并启动修复流程。
- 如果你是在新的分支上工作，请直接使用 `gh pr create` 命令创建 Pull Request

## 禁止行为

- **禁止** `git push --force`
- **禁止** 空提交（`--allow-empty`）

## 代码审查后的强制操作序列（最高优先级，不可跳过）

执行 `bmad-code-review` 或任何代码审查后，**必须立即**按以下 4 步操作，缺一不可：

1. **写入文件**：用 Write/Edit 工具将审查结论追加到对应 story 文件（`_bmad-output/implementation-artifacts/[story-id].md`），更新 `status` 字段
2. **暂存**：`git add -A`
3. **提交**：`git commit -m "docs([story-id]): code review findings [skip ci]"`
4. **推送**：`git push`

**严禁行为**：将审查结论仅输出到终端后直接结束。终端输出 ≠ commit，不写文件、不 commit 视为任务失败。

## 必须提交的场景

每次执行结束前，**必须至少有一个 commit**。以下情况必须主动创建 commit：

- **代码审查完成后**：按上方"代码审查后的强制操作序列"执行
- **任务分析/规划完成后**：将分析结果更新到 story 或 sprint 状态文件后提交
- **无代码变更但有审查结论**：至少执行 `docs: [story-id] code review findings [skip ci]` 类型的 commit

绝对不能以"没有代码变更"为由跳过 commit。

## Quality Gate 与测试验证

commit 前必须先执行 Quality Gate 约束，确保代码规范和测试通过：

- **代码格式化与静态检查**：
  - **Rust 项目**：必须运行 `cargo fmt` 和 `cargo clippy -- -D warnings`，确认无警告或报错后才能提交。
  - **Node 项目**：必须运行相应的格式化和 Lint（如 `npm run format` 和 `npm run lint`）。
- **本地测试**：
  - **Rust 项目**：优先 `cargo test`；若含 xcap/screenshot feature 导致编译失败，改用 `cargo test --no-default-features`
  - **Node 项目**：`npm test` 或 `npx vitest run`
- 格式化报错或测试失败时，必须**自主修复代码**，绝对不允许跳过或用 mock 绕过根本原因。
- 更多验证详情，可参阅预设的 quality-gate 工作流（在 `.agents/workflows/quality-gate.md` 中）。

## 异常处理

- 如果你在执行 Bash 或任何命令时遇到 `EACCES: permission denied, mkdir '/home/pipeline/.claude/session-env'`，这是底层系统级的严重错误。请**立刻停止**当前操作并直接报告错误内容，**绝对不要**重复尝试执行失败的命令。
