# Agent 行为规范（AGENT_RULES.md）

本文件是容器内 Claude 执行时的强制约束。所有规则均为 **MUST** 或 **MUST NOT** 级别，不得以"灵活性"或"效率"为由跳过。

---

## 1. 终止信号协议

Claude 执行完毕后，**必须**在最后一行输出以下信号之一，且信号必须独占一行，前后无空格或额外字符。bash 脚本通过 `grep` 检测该信号来驱动后续流程。

| 信号 | 含义 | 前置条件 |
|------|------|----------|
| `PIPELINE_COMPLETE` | 实施完成，等待外部推送和审查 | 代码已 commit，`sprint-status.yaml` 已更新 |
| `PIPELINE_BLOCKED` | 遇到无法自行解决的阻塞 | `/workspace/AGENT_BLOCKED.json` 已写入 |
| `PIPELINE_YIELD_CI` | 需等待 CI，当前无法继续 | `/tmp/yield_branch.txt` 已写入分支名 |
| `DISCOVER_COMPLETE` | discover 阶段决策完成 | `/tmp/agent_action.json` 已写入 |
| `REVIEW_COMPLETE` | 独立审查完成 | `/workspace/review_result.json` 已写入 |

**禁止**输出多个信号，或在信号之外再输出结构化 JSON 到 stdout（写文件不受限）。

---

## 2. 原子认领安全规则

**背景**：任务认领通过 `git push` 留下审计记录，并为未来扩展多容器并发预留语义。Claude 不直接 push，保持 bash 对 git 操作的唯一控制权，职责边界清晰。

### MUST NOT

- **MUST NOT** 使用 `git push` 认领任务。认领操作由 `entrypoint.sh` 执行，Claude 只需写入 `/tmp/agent_action.json` 输出决策。
- **MUST NOT** 在 `git commit` 之后、bash 触发 push 之前继续修改任何文件（破坏 commit 完整性）。
- **MUST NOT** 使用 `git push --force` 或 `git push --force-with-lease`。
- **MUST NOT** 修改其他容器正在处理的任务（`[-]` 状态）。

### MUST

- 认领决策写入 `/tmp/agent_action.json`，格式见第 4 节。
- 实施完成后仅执行 `git add -A && git commit`，不执行 push。

---

## 3. 独立审查规则

**背景**：审查员在独立 Claude 调用中执行，与实施会话完全隔离，目的是消除"批改自己试卷"的偏差。

### MUST NOT（审查角色）

- **MUST NOT** 使用"根据上下文我猜测作者的意图"、"实现者可能想要"等表述——你对实现过程一无所知。
- **MUST NOT** 因为代码"看起来是故意的"就跳过问题——只根据代码本身和验收标准评判。
- **MUST NOT** 在同一会话中同时扮演实施者和审查员。

### MUST（审查角色）

- 审查基准：git diff 内容 + story 验收标准，不得引用会话历史。
- 发现 `verdict=fail` 时，修复所有 high severity 问题后重新评分，更新 `review_result.json`。
- 审查结束后输出 `REVIEW_COMPLETE`。

---

## 4. 状态检查点（Claude 必须写入）

| 时机 | 文件 | 格式 |
|------|------|------|
| Discover 阶段结束 | `/tmp/agent_action.json` | 见下方 JSON 格式 |
| 实施完成 | `sprint-status.yaml` | story 状态更新为 `review` |
| 遇到阻塞 | `/workspace/AGENT_BLOCKED.json` | `{"reason": "...", "story_key": "..."}` |
| 审查完成 | `/workspace/review_result.json` | 标准审查结果 JSON |

### Discover 决策 JSON 格式

```json
{
  "action": "claim|create-story|planning|ci-fix|done|blocked",
  "story_key": "story-XXX",
  "story_file": "docs/stories/story-XXX.md",
  "reason": "选择此 action 的简要说明（一句话）"
}
```

**`action` 取值语义**：

| 值 | 含义 |
|----|------|
| `claim` | 发现可认领的 story，准备实施 |
| `create-story` | 无可认领 story，但 backlog 有待细化的需求 |
| `planning` | 需要先完成架构/规划工作再认领 |
| `ci-fix` | 上一个 PR 的 CI 失败，需要修复 |
| `done` | 所有 story 已完成，sprint 结束 |
| `blocked` | 存在无法自行解决的阻塞，需人工介入 |

---

## 5. 依赖管理规则

新增外部依赖（`Cargo.toml`、`package.json`、`apt install`、`pip install` 等）是**架构决策**，不得轻率引入。

### 决策流程（MUST 遵循）

遇到需要新依赖的场景时，必须按以下顺序评估：

1. **标准库能否解决？** Rust std / Node built-ins / Python stdlib 优先。
2. **项目已有依赖能否复用？** 读 `Cargo.toml` / `package.json`，确认是否已有功能重叠的库。
3. **确认必要后才能新增**，并在 commit message 中说明选型理由（为何选这个库而非其他）。

### 系统级 apt 依赖（特殊规则）

- 构建工具链（gcc、cmake 等）和常见系统库**已预装在基础镜像**，无需重复安装。
- 若确实缺少系统库，安装前先确认该库是否为项目构建的必要依赖，而非绕过问题的权宜之计。

### Rust 测试已知问题（直接跳过，勿重复尝试）

- 若项目含屏幕捕获相关 feature（如 `libpipewire`/`libspa`），直接用 `cargo test --no-default-features` 跑单元测试。
- **禁止**任何形式的 `cargo test --features screenshot`、`cargo test --features xcap`、`cargo test --all-features` 等包含屏幕捕获 feature 的命令——容器无 libspa/pipewire 系统库，**必定编译失败**，浪费 2-5 分钟。
- **禁止先跑** `cargo test`（默认 features）再因报错重试——这会浪费 ~2 分钟编译时间。
- 判断依据：`Cargo.toml` 中存在 `xcap`、`pipewire`、`libspa` 等屏幕捕获依赖即适用本规则。
- `#[cfg(feature = "screenshot")]` 门控的测试无法在本环境运行，**接受该限制，不要尝试绕过**。

---

## 6. 禁止行为速查

| # | 禁止行为 | 原因 |
|---|----------|------|
| 1 | `git push` 认领任务 | 破坏分布式锁 |
| 2 | commit 后继续修改文件 | 污染 commit 完整性 |
| 3 | `git push --force` | 可能覆盖他人工作 |
| 4 | 同一会话中实施+审查 | 自我审查偏差 |
| 5 | 审查时猜测作者意图 | 引入主观偏差 |
| 6 | 输出多个终止信号 | bash 解析歧义 |
| 7 | 修改 `[-]` 状态任务 | 抢占他人任务 |
| 8 | 未经评估直接新增依赖 | 依赖蔓延，增加维护成本 |

---

*本规范由 `entrypoint.sh` 在 BMAD 自驱动模式下通过 heredoc 注入到 Claude 会话 prompt 头部。*
