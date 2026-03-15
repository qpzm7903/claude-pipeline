---
description: Pipeline CI/CD Quality Gate
---

# Quality Gate Workflow

你在完成代码变更后，**必须**执行以下步骤来保证代码质量，绝不能跳过。这是对齐 BMAD 方法论的 Quality Gate 检查：

## 1. Code Formatting (代码格式化)
// turbo
确保代码风格严格符合仓库标准。如果格式化命令报错，必须自主修复。
- Rust 项目：运行 `cargo fmt`
- Node 及其它项目：运行 `npm run format` 或对应格式化命令

## 2. Static Analysis (静态分析)
修复所有的警告和错误，绝不允许带有警告提交。
- Rust 项目：运行 `cargo clippy -- -D warnings`
- Node 及其它项目：运行 `npm run lint` 等

## 3. Local Test Execution (本地测试)
运行单元与集成测试。绝对不能使用 mocked workarounds 绕过核心逻辑测试。
- Rust 项目：运行 `cargo test` （或 `cargo test --no-default-features`）
- Node 及其它项目：运行 `npm test` 或 `npx vitest run`

## 4. Pre-Commit QA Review (提交前自审)
带入 "Test Architect / QA" 角色。问自己："这次提交会破坏线上的 CI 持续集成吗？"。
确认无误后，再执行 `git commit` 以及随后的 `git push` 和 CI 状态验证。
