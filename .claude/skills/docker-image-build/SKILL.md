---
name: docker-image-build
description: Build Docker images for the claude-pipeline project. Use this skill whenever the user asks to build, rebuild, update, or push Docker images for the pipeline agent. Also triggers when fixing permission errors, updating Dockerfile, or deploying changes to the pipeline container. Always use this skill instead of guessing the build commands — it avoids known pitfalls like missing base image, stale layer cache, and EACCES runtime errors.
---

# Docker Image Build — Claude Pipeline

本项目的 Docker 镜像分为**两层**，必须按顺序构建：

```
Dockerfile.base  →  claude-pipeline-base:latest
Dockerfile       →  claude-pipeline-agent:latest
```

如果跳过 base 镜像直接构建 agent，Docker 会报错：
```
pull access denied, repository does not exist or may require authorization
```

---

## 标准构建流程

所有命令均在项目根目录 `/Users/weiyicheng/workspace/06_ai/09_claude_pipline`（或仓库根）执行。

### 步骤 1：构建 base 镜像

```bash
docker build \
  -t claude-pipeline-base:latest \
  -f ./agent/Dockerfile.base \
  ./agent/
```

**何时可跳过**：如果只修改了 `entrypoint.sh`、`container-CLAUDE.md` 等 agent 层文件，且 base 镜像已存在且未变更，可跳过此步骤直接构建 agent。

**何时必须重建 base**：
- 修改了 `Dockerfile.base`（如新增系统包、更改 Rust/Node 版本）
- 本地没有 `claude-pipeline-base:latest`（首次构建 / 机器迁移后）
- 执行 `docker images | grep claude-pipeline-base` 无输出

### 步骤 2：构建 agent 镜像

```bash
docker build \
  -t claude-pipeline-agent:latest \
  ./agent/
```

---

## 构建后验证

### 验证权限修复（重要！）

历史上曾因 `/home/pipeline/.claude` 目录 owner 为 root，导致 Claude Code 在容器内完全无法执行 Bash 命令（`EACCES: permission denied, mkdir '/home/pipeline/.claude/session-env'`）。

构建完毕后，运行以下命令验证权限正确：

```bash
docker run --rm --entrypoint stat \
  claude-pipeline-agent:latest \
  /home/pipeline/.claude
```

**期望输出**中必须包含：
```
Uid: (1000/pipeline)
```

若 owner 是 root（Uid: 0），说明 Dockerfile 中缺少 `chown`，需修复后重建。

### 验证入口脚本可执行

```bash
docker run --rm --entrypoint ls \
  claude-pipeline-agent:latest \
  -la /agent/entrypoint.sh
```

应看到 `-rwxr-xr-x`（有执行权限）。

---

## 快速一键构建（两层全量构建）

```bash
docker build -t claude-pipeline-base:latest -f ./agent/Dockerfile.base ./agent/ \
  && docker build -t claude-pipeline-agent:latest ./agent/
```

---

## 常见错误与处理

| 错误信息 | 原因 | 解决方法 |
|----------|------|----------|
| `pull access denied ... claude-pipeline-base` | agent 的 base 镜像不存在于本地 | 先执行步骤 1 构建 base 镜像 |
| `EACCES: permission denied, mkdir '/home/pipeline/.claude/session-env'` | `.claude` 目录 owner 是 root | 确认 Dockerfile 第 12 行有 `chown pipeline:pipeline`，重建镜像 |
| `failed to solve: ... network timeout` | 网络超时（下载 Rust/Node 等） | 重试，或检查网络代理设置 |
| Pod 显示 Completed 但仓库无变化 | Claude exit 0 但实际未 commit | entrypoint.sh 已有 BEFORE/AFTER_COMMIT 检测，会以 exit 3 报错 |

---

## Dockerfile 关键结构说明

### Dockerfile.base 要点
- 基于 `ubuntu:22.04`
- 创建非 root 用户 `pipeline`（UID=1000）
- 以 `pipeline` 用户安装 Rust，使 `~/.cargo` 归属正确
- 设置 `ENV PATH="/home/pipeline/.cargo/bin:${PATH}"`

### Dockerfile（agent）要点
- 从 `claude-pipeline-base:latest` 继承
- **以 root 执行所有 RUN**，最后切换回 `USER pipeline`
- `.claude` 目录必须 `chown pipeline:pipeline`，否则 Claude Code 无法创建 `session-env`：
  ```dockerfile
  RUN mkdir -p /home/pipeline/.claude && chown pipeline:pipeline /home/pipeline/.claude
  ```
- `container-CLAUDE.md` 被复制到 `/home/pipeline/.claude/CLAUDE.md`，作为容器内的全局规则

---

## K8s 部署注意事项

构建完新镜像后，若 K8s CronJob 的 `imagePullPolicy` 是 `IfNotPresent`，需手动触发更新：

```bash
# 检查当前 imagePullPolicy
kubectl get cronjob claude-pipeline-qpzm7903-dailylogger \
  -n claude-pipeline -o yaml | grep imagePullPolicy

# 若使用私有 registry，推送镜像后 Pod 重启时会自动拉取
# 若使用本地镜像（开发环境），需确认 imagePullPolicy: Never
```
