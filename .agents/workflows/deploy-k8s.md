---
description: 构建 Docker 镜像并更新 K8s CronJob（使用指定 env 文件）
---

# 部署流程

将本地代码变更构建成 Docker 镜像，并更新 Kubernetes CronJob。

## 步骤

1. 提交所有未提交的变更

```bash
git add -A && git status
```

检查暂存区，仅提交相关文件（排除 .db-shm、.db-wal、scheduled_tasks.lock 等运行时临时文件）：

```bash
git diff --cached --name-only
```

确认后提交：

```bash
git commit -m "<type>(<scope>): <description>"
git push
```

2. 构建 Docker 镜像

如果 `claude-pipeline-base:latest` 本地不存在（首次或 Dockerfile.base 有改动时才需要）：

```bash
docker build -t claude-pipeline-base:latest -f agent/Dockerfile.base ./agent/ 2>&1 | tail -5
```

构建 agent 镜像（每次部署都要执行）：

// turbo
```bash
docker build -t claude-pipeline-agent:latest ./agent/ 2>&1 | tail -8
```

3. 更新 K8s CronJob

使用 litellm.env 部署到 K8s（自动读取 litellm.env 中的 GIT_REPO_URL）：

// turbo
```bash
./k8s-run.sh --env litellm.env 2>&1
```

4. 确认部署状态

// turbo
```bash
./k8s-run.sh --status 2>&1
```

5. （可选）触发立即执行并查看日志

手动触发一次 Job：

```bash
CRONJOB=$(kubectl get cronjob -n claude-pipeline -l app.kubernetes.io/name=claude-pipeline -o jsonpath='{.items[0].metadata.name}')
kubectl create job --from=cronjob/${CRONJOB} -n claude-pipeline ${CRONJOB}-manual-$(date +%s)
```

跟踪日志：

```bash
./k8s-run.sh --logs -f
```
