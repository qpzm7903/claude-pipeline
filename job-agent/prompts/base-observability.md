# 可观测性规则

你的工作过程必须是可追踪和可复盘的。

---

## 进度日志

每次任务**开始时**和**结束时**，必须将记录追加到代码仓库根目录下的 `.agent-progress.md` 文件中。

### 任务开始时追加

```markdown
### Session N — <当前时间>
- **任务类型**: <ut-gen / feature-dev / refactor / perf-optimize / bug-fix>
- **目标**: <一句话描述本轮目标>
- **状态**: 🔄 进行中
```

### 任务结束时更新

将该 session 的记录更新为：

```markdown
### Session N — <当前时间>
- **任务类型**: <ut-gen / feature-dev / refactor / perf-optimize / bug-fix>
- **目标**: <一句话描述>
- **状态**: ✅ 成功 / ⚠️ 部分完成 / ❌ 回滚
- **版本**: <v0.x.y 或 "未发布">
- **产出**: <新增/修改了哪些文件>
- **详情**: <一句话总结关键改动>
```

### 规则
- `.agent-progress.md` 中的记录**只追加不删除**
- Session 编号从文件中已有记录推断（首次为 1）
- 该文件随代码一起 commit 和 push

---

## 决策追踪

关键决策点的推理过程已由 `base-system.md` 中的"思维链规则"覆盖。
这里强调：**决策推理的输出会自动成为 session 日志的一部分**，无需额外记录。

---

## 错误记录

当构建失败或测试失败时，在 `.agent-progress.md` 的当前 session 中追加：

```markdown
- **错误**: <错误类型，如 "编译失败" / "UT 失败">
- **摘要**: <错误信息的关键行，最多 3 行>
- **处理**: <修复 / 回滚 / 跳过>
```

---

## 输出控制

重申：所有构建和测试的标准输出**必须重定向到文件**，仅查看最后若干行：
```bash
<command> > /tmp/output.log 2>&1
echo "EXIT: $?" >> /tmp/output.log
tail -20 /tmp/output.log
```

这样做的目的是**避免长输出占满上下文窗口导致 Agent 性能下降**。
