# 重构后 K8s Pod 运行问题汇总

> 检查时间：2026-03-15
> 涉及 namespace：`claude-pipeline`
> CronJob：`claude-pipeline-qpzm7903-dailylogger`（`*/10 * * * *`）

---

## Pod 运行概况

| Pod | 状态 | 年龄 |
|-----|------|------|
| 29558960-xg8mm | ❌ Error (BackoffLimitExceeded) | 66m |
| r7ljk-nrlq7    | ❌ Error (BackoffLimitExceeded) | 12m |
| 29558990-vnnhn | ✅ Completed（虚假成功） | 40m |
| 29559000-686lq | ✅ Completed（虚假成功） | 27m |
| 29559020-hmgf7 | 🔄 Running | 6m |

---

## 🔥 问题一（最高优先级 · 反复出现）：所有 Bash 调用全部失败

**现象**：
```
Error: EACCES: permission denied, mkdir '/home/pipeline/.claude/session-env'
```

**出现频率**：**每个 Pod 中每一次 Bash 工具调用都报此错**，包括：
- `cargo test`
- `npm run test`
- `git add / git commit / git push`
- `whoami`、`pwd` 等最简单命令
- Claude 创建 shell 脚本后用 `bash script.sh` 执行也失败

**根本原因**：`Dockerfile` 中 `mkdir -p /home/pipeline/.claude` 以 root 执行，目录 owner 是 root。Claude Code 启动时需要在该目录下创建 `session-env`，但容器用户是 `pipeline`，没有写权限，导致 Claude Code **工具执行引擎完全瘫痪**。

**已修复**（`agent/Dockerfile:12`）：
```dockerfile
# 修复前
RUN mkdir -p /home/pipeline/.claude

# 修复后
RUN mkdir -p /home/pipeline/.claude && chown pipeline:pipeline /home/pipeline/.claude
```

**⚠️ 当前镜像尚未重建**，所有运行中的 Pod 仍使用旧镜像，问题持续存在。

**必须行动**：
```bash
docker build -t claude-pipeline-agent:latest ./agent/
# 然后触发 k8s 重新拉取新镜像
```

---

## 问题二（高优先级）：Completed 状态是虚假成功

**现象**：2 个 Job 显示 `Complete`，但实际上：
- Claude 未能运行任何测试
- 未执行任何 `git commit`
- 未执行任何 `git push`
- 目标仓库代码无任何变化

**原因**：`entrypoint.sh` 中的退出判断仅检查 Claude 进程的退出码。Claude 本身以 exit 0 退出（成功完成了文本分析和规划），但所有实际操作（Bash 工具调用）均失败。K8s 因此误判 Job 为 Completed。

**影响**：无法通过 Job 状态来判断"pipeline 是否真正完成了工作"，监控失效。

---

## 问题三（中优先级）：Bash 完全失效时 Claude 反复重试同一失败命令

**现象（在 29559020 pod 中观测到）**：
```
> Bash    npm run test -- --run 2>&1 | head -100
| Error: EACCES: permission denied, ...
> Bash    npm run test -- --run 2>&1 | head -100
| Error: EACCES: permission denied, ...
> Bash    npm run test -- --run 2>&1 | head -100
| Error: EACCES: permission denied, ...
（共重试 6 次）
```

**原因**：Claude 不理解 `EACCES` 是环境级别的系统性错误，将其当作偶发的命令错误来重试。

**建议**：在 `container-CLAUDE.md` 中加入提示，告知 Claude 遇到 `EACCES: session-env` 错误时应立即停止并报告，而不是重试。

---

## 问题四（中优先级）：Prompt too long 导致任务提前中止

**现象**（在 r7ljk-nrlq7 pod 日志末尾）：
```
* Prompt is too long
[done] success  turns=75  cost=$0.0000  704s
```

**原因**：Claude 上下文累积过长（75 轮对话），最终触发模型 prompt 长度限制，任务被截断，后续的 commit/push 未执行。

**建议**：考虑在 entrypoint 的 PROMPT 中要求 Claude 更早执行 commit（在完成每个 Story 后立即 commit，而非全部完成后统一 commit）。

---

## 问题五（低优先级）：第一个 Failed Job 日志无法获取

**现象**：
```bash
kubectl logs claude-pipeline-qpzm7903-dailylogger-29558960-xg8mm -n claude-pipeline
# → unable to retrieve container logs for docker://970a4087...
```

Docker 层面的容器日志已丢失，无法追溯该 Job 的失败原因。

---

## 修复优先级

| # | 问题 | 优先级 | 状态 |
|---|------|--------|------|
| 1 | `.claude` 目录权限错误 → 所有 Bash 失败 | 🔴 最高 | 代码已修复，**需重建镜像** |
| 2 | Completed 状态虚假成功 | 🟠 高 | 待评估如何检测真正的成功 |
| 3 | Claude 反复重试系统级错误 | 🟡 中 | 建议在 container-CLAUDE.md 加提示 |
| 4 | Prompt too long 中止任务 | 🟡 中 | 建议分阶段 commit |
| 5 | 旧 Pod 日志丢失 | 🟢 低 | 可接受 |

---

## 立即执行

```bash
# 1. 重建 agent 镜像（已包含 .claude 目录权限修复）
docker build -t claude-pipeline-agent:latest ./agent/

# 2. 验证权限修复
docker run --rm --entrypoint stat claude-pipeline-agent:latest /home/pipeline/.claude
# 期望输出：File: /home/pipeline/.claude  Uid: 1000 (pipeline)

# 3. 下一个 CronJob 触发时会自动拉取新镜像（imagePullPolicy 需确认）
```
