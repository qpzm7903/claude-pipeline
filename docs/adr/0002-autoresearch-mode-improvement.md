# Autoresearch 模式改进分析（草案）

> 状态：草案，待决策
> 日期：2026-03-17
> 基于：Pod `claude-pipeline-qpzm7903-dailylogger-newapi-9kg6w-zx9bh` 运行观察（135min，15+ 轮内部迭代）

---

## 1. 问题诊断

### 1.1 两层循环冲突

当前架构存在两个独立的循环机制，互相矛盾：

```
┌─ entrypoint.sh 外层循环（AUTO_ITERATE=true）──────────┐
│  while true; do                                        │
│    _run_claude  ←── Claude 永远不退出，卡在这里        │
│    # 以下代码永远执行不到：                             │
│    #   检查 commit → push → cooldown → 重启 Claude     │
│  done                                                  │
└────────────────────────────────────────────────────────┘

┌─ Prompt 内层循环（LOOP FOREVER）──────────────────────┐
│  步骤1: 决策 → 步骤2: 实现 → 步骤3: 验证              │
│  → 步骤4: commit/discard → 步骤5: 更新进度             │
│  → 步骤6: 回到步骤1（永远不退出）                      │
└────────────────────────────────────────────────────────┘
```

**结果**：entrypoint 的崩溃重启、commit 检测、push 兜底、cooldown 等机制全部失效。

### 1.2 实际观察到的退化

| 时间段 | 行为 | 效率 |
|--------|------|------|
| 0-60min | 高产出：FTS5 修复、v1.13.2 发版、README 更新 | 高 |
| 60-90min | 正常：Dependabot、LICENSE、.editorconfig | 中 |
| 90-135min | 空转：连续 Grep/Read 分析，无 commit | 低 |

原因：
- **Context 膨胀**：1408 行日志 = 大量工具调用历史占用 context window
- **项目成熟**：0 warnings、349 tests pass、无 TODO，找不到改进目标
- **无退出机制**：Prompt 说 "LOOP FOREVER"，Claude 无法主动退出

### 1.3 设计意图 vs 实际行为

| 机制 | 设计意图 | 实际行为 |
|------|---------|---------|
| entrypoint while 循环 | 每轮重启 Claude（干净 context） | 永远卡在第一轮 |
| `_CONSECUTIVE_FAILS` | 连续失败 5 次退出 | 从未触发 |
| `git push` 兜底 | 每轮结束自动 push | 从未执行 |
| `git pull --rebase` | 拉取其他 agent 的推送 | 从未执行 |
| `MAX_ITERATIONS` | 限制总迭代次数 | 从未检查 |
| `.auto-progress.md` | 跨轮次状态传递 | 仅在单会话内更新 |

---

## 2. 改进方案

### 方案 A：单轮 Prompt（推荐）

**核心思路**：Prompt 只指导 Claude 做一轮迭代，然后正常退出。由 entrypoint.sh 外层循环负责重启。

**Prompt 改动**：

```diff
- **LOOP FOREVER** — 重复以下步骤，直到被外部终止：
+ **单轮执行** — 完成以下步骤后正常退出：

  步骤 1-5 保持不变

- ### 步骤 6: 回到步骤 1
- 不要停下来。不要问人类。继续下一轮。
+ ### 步骤 6: 退出
+ 本轮完成，正常结束。外部调度器会自动重启你并提供干净 context。
+ `.auto-progress.md` 保留了所有历史，下次启动你会从那里恢复。

  关键规则改动：
- 7. 监控 context 使用量。如果你感觉 context 快满了...主动退出
+ 7. （删除——不再需要自评 context）
```

**优点**：
- entrypoint 所有机制生效：commit 检测、push 兜底、cooldown、MAX_ITERATIONS
- 每轮 context 干净，不会退化
- 崩溃自动恢复
- `git pull --rebase` 可以拉取其他 agent 的推送

**缺点**：
- 每轮重新克隆 + 读 .auto-progress.md 的开销（约 30-60s）
- 跨轮次 context 丢失（但 .auto-progress.md 补偿）

**适用场景**：长时间运行的自主开发（当前主要用例）

### 方案 B：限时内循环

**核心思路**：Prompt 仍然内循环，但加入时间/轮次上限，到达后主动退出。

**Prompt 改动**：

```diff
- **LOOP FOREVER** — 重复以下步骤，直到被外部终止：
+ **限时执行** — 重复以下步骤，最多 5 轮或 30 分钟后退出：

+ ### 退出条件（任一满足即退出）
+ - 已完成 5 轮迭代
+ - 连续 2 轮无 commit（项目已无简单改进）
+ - 感觉 context 使用量较高
```

**优点**：
- 短期内保留 context 连续性（前几轮效率高）
- 仍能享受 entrypoint 重启机制（限时后退出）
- 平衡了效率和 context 管理

**缺点**：
- 依赖 Claude 准确计数和自评（不完全可靠）
- 比方案 A 复杂，调试更难

**适用场景**：希望在一次会话内完成关联性强的多步任务

### 方案 C：混合模式（entrypoint 强制超时）

**核心思路**：Prompt 不改，entrypoint 加超时强杀。

**entrypoint.sh 改动**：

```bash
# 在 _run_claude 外包一层 timeout
_ROUND_TIMEOUT="${ROUND_TIMEOUT:-1800}"  # 每轮最多 30 分钟
timeout "$_ROUND_TIMEOUT" bash -c '_run_claude' || _EXIT=$?
```

**优点**：
- 不依赖 Claude 的自我约束
- 100% 可靠的超时保证
- Prompt 无需改动

**缺点**：
- timeout SIGTERM 可能中断正在进行的 git 操作
- 需要信号处理（trap）确保不丢数据
- Claude 被强杀后 .auto-progress.md 可能未更新

**适用场景**：作为安全网，防止 Claude 无限运行

---

## 3. 方案对比

| 维度 | A: 单轮 Prompt | B: 限时内循环 | C: 强制超时 |
|------|----------------|---------------|-------------|
| **可靠性** | 高（entrypoint 控制） | 中（依赖 Claude） | 高（OS 级） |
| **效率** | 中（每轮重启开销） | 高（前几轮） | 中（可能打断） |
| **复杂度** | 低 | 中 | 中 |
| **数据安全** | 高（干净退出） | 高（干净退出） | 低（可能中断 git） |
| **调试友好** | 高（每轮独立日志） | 低（长日志） | 中 |
| **context 管理** | 完美（每轮干净） | 一般（会膨胀） | 差（被杀时最大） |
| **改动范围** | Prompt 文件 | Prompt 文件 | entrypoint.sh |

---

## 4. 推荐方案

**主方案：A + C 组合**

1. **Prompt 改为单轮执行**（方案 A）：Claude 每轮做一个改进就退出
2. **entrypoint 加安全超时**（方案 C 作为安全网）：防止 Claude 偶尔不遵守单轮指令

```bash
# entrypoint.sh 改动
_ROUND_TIMEOUT="${ROUND_TIMEOUT:-1800}"  # 默认 30 分钟

timeout "$_ROUND_TIMEOUT" bash -c '
  claude --dangerously-skip-permissions --print --verbose \
    --output-format stream-json <<< "${PROMPT}" 2>&1
' | _fmt_stream
```

3. **Prompt 加入"无改进则退出"逻辑**：

```
如果分析后发现没有值得做的改进（项目已趋于成熟），
在 .auto-progress.md 中记录"无可用改进"后正常退出。
不要强行寻找低价值任务。
```

---

## 5. 需要决策的问题

1. **选哪个方案？** A（单轮）/ B（限时内循环）/ C（强制超时）/ A+C（推荐组合）
2. **每轮超时设多少？** 推荐 30 分钟（当前观察：高效阶段约 10-15 分钟/轮）
3. **迭代间 cooldown 多久？** 当前默认 10s，是否需要调整？
4. **MAX_ITERATIONS 是否设上限？** 当前默认 0（无限），是否设为如 50？
5. **"无改进"退出策略**：连续几轮无 commit 后退出？推荐 2 轮
6. **是否保留 Prompt 内 "LOOP FOREVER" 作为备选模式？** 可通过环境变量切换

---

## 6. 附录：当前文件清单

| 文件 | 作用 | 改动范围 |
|------|------|---------|
| `agent/auto-iterate-prompt.txt` | 自主迭代 Prompt（镜像内置） | 方案 A/B 主改 |
| `agent/entrypoint.sh:302-349` | autoresearch 外层循环 | 方案 C 主改 |
| `k8s/render_and_apply.py` | CronJob 渲染（传递 env） | 新增 ROUND_TIMEOUT |
| `config/config.yaml` | 全局配置 | 可选：添加 round_timeout |
