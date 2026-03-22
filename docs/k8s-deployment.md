# Claude Pipeline Kubernetes 部署文档

本文档提供完整的 Kubernetes 部署方案，可在新环境快速部署。

## 目录

- [环境要求](#环境要求)
- [快速部署](#快速部署)
- [部署清单说明](#部署清单说明)
- [配置说明](#配置说明)
- [常用命令](#常用命令)
- [卸载](#卸载)

---

## 环境要求

| 组件 | 版本要求 | 说明 |
|------|----------|------|
| Kubernetes | 1.24+ | Docker Desktop K8s / kind / minikube 等 |
| kubectl | 1.24+ | 命令行工具 |
| Docker | 20.10+ | 构建镜像 |
| helm | 3.x | 可选，用于部署 Rancher Dashboard |

---

## 快速部署

### 方式一：一键部署（推荐）

```bash
# 1. 构建 Docker 镜像
docker build -t claude-pipeline-base:latest -f agent/Dockerfile.base ./agent/
docker build -t claude-pipeline-agent:latest ./agent/

# 2. 创建 Secret（填入真实值）
# 获取 base64 编码: echo -n 'your-api-key' | base64
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/cargo-cache-pvc.yaml
kubectl apply -f k8s/secret.yaml  # 需要先从 secret.yaml.example 复制并编辑

# 3. 部署 CronJob
./k8s-run.sh
```

### 方式二：使用 env 文件部署（无需预创建 Secret）

```bash
# 1. 构建 Docker 镜像
docker build -t claude-pipeline-base:latest -f agent/Dockerfile.base ./agent/
docker build -t claude-pipeline-agent:latest ./agent/

# 2. 准备 env 文件
cat > .env.myconfig << 'EOF'
ANTHROPIC_AUTH_TOKEN=sk-xxx
ANTHROPIC_BASE_URL=https://api.anthropic.com
ANTHROPIC_MODEL=claude-sonnet-4-20250514
GIT_TOKEN=ghp_xxx
GIT_REPO_URL=https://github.com/owner/repo
EOF

# 3. 部署 CronJob（env 直接注入 pod）
./k8s-run.sh --env .env.myconfig --name my-pipeline
```

---

## 部署清单说明

### 核心资源

| 文件 | 资源类型 | 说明 |
|------|----------|------|
| `k8s/namespace.yaml` | Namespace | 创建 `claude-pipeline` 命名空间 |
| `k8s/rbac.yaml` | ServiceAccount | 创建服务账户 |
| `k8s/cargo-cache-pvc.yaml` | PersistentVolumeClaim | 缓存存储（10Gi） |
| `k8s/secret.yaml` | Secret | 敏感信息（API Key、Git Token） |
| `k8s/cronjob-template.yaml` | CronJob 模板 | 由 `render_and_apply.py` 渲染 |

### 资源依赖关系

```
namespace.yaml
    └── rbac.yaml (依赖 namespace)
    └── cargo-cache-pvc.yaml (依赖 namespace)
    └── secret.yaml (依赖 namespace)
        └── cronjob-template.yaml (依赖以上所有)
```

---

## 配置说明

### config/config.yaml

```yaml
docker:
  image: "claude-pipeline-agent:latest"
  mem_limit: "4g"
  cpu_quota: 100000

anthropic:
  model: "claude-opus-4-5-20251001"  # 可被环境变量覆盖

git:
  author_name: "Claude Pipeline Bot"
  author_email: "pipeline@claude.ai"
  branch_prefix: "task/"
  commit_prefix: "feat"

kubernetes:
  schedule: "*/10 * * * *"      # CronJob 触发频率
  image_pull_policy: "Never"    # Never=本地镜像; IfNotPresent=远端镜像
  namespace: "claude-pipeline"
  job_deadline_seconds: 0       # 0=不限制运行时间
```

### config/repos.yaml

```yaml
repos:
  - name: "my-project"
    url: "https://github.com/owner/repo"
    default_branch: "main"
    task_source: "plan_md"
    plan_file: "plan.md"
    test_command: "cargo test"
    language: "rust"
    enabled: true
```

### 环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `ANTHROPIC_AUTH_TOKEN` | ✅ | API Key（或 `ANTHROPIC_API_KEY`） |
| `ANTHROPIC_BASE_URL` | 可选 | API 地址（如 DashScope 代理） |
| `ANTHROPIC_MODEL` | 可选 | 模型名称 |
| `GIT_TOKEN` | ✅ | GitHub PAT（需要 `repo` + `pull_requests` 权限） |
| `GIT_REPO_URL` | 可选 | 目标仓库 URL（也可在命令行指定） |

---

## 常用命令

### 部署管理

```bash
# 查看所有资源状态
./k8s-run.sh --status

# 查看 CronJob 详情
kubectl get cronjob -n claude-pipeline

# 查看 Job 运行历史
kubectl get jobs -n claude-pipeline --sort-by=.metadata.creationTimestamp

# 查看 Pod 日志
./k8s-run.sh --logs
./k8s-run.sh --logs -f  # 实时跟踪
```

### 手动触发

```bash
# 手动触发一次执行
kubectl create job --from=cronjob/claude-pipeline-<repo-slug> manual-$(date +%s) -n claude-pipeline

# 示例
kubectl create job --from=cronjob/claude-pipeline-qpzm7903-dailylogger manual-test-1 -n claude-pipeline
```

### 更新 Secret

```bash
# 使用当前 .env 更新 K8s Secret
./k8s-run.sh --update-secret
```

### 删除 CronJob

```bash
# 删除所有 CronJob
./k8s-run.sh --delete

# 删除单个 CronJob
kubectl delete cronjob claude-pipeline-<repo-slug> -n claude-pipeline
```

---

## 卸载

```bash
# 删除所有 CronJob
./k8s-run.sh --delete

# 删除所有资源
kubectl delete -f k8s/cronjob-template.yaml  # 如果有生成的 CronJob
kubectl delete -f k8s/secret.yaml
kubectl delete -f k8s/cargo-cache-pvc.yaml
kubectl delete -f k8s/rbac.yaml
kubectl delete -f k8s/namespace.yaml

# 或直接删除 namespace（会级联删除其中所有资源）
kubectl delete namespace claude-pipeline
```

---

## 附录

### A. Docker Desktop K8s 使用本地镜像

Docker Desktop 的 Kubernetes 与 Docker 共享镜像缓存：

- 设置 `image_pull_policy: "Never"` 使用本地镜像
- 无需推送镜像到 Registry
- 镜像更新后重新构建即可

### B. 使用 DashScope 代理

```bash
# .env 文件配置
ANTHROPIC_AUTH_TOKEN=sk-xxx
ANTHROPIC_BASE_URL=https://dashscope.aliyuncs.com/apps/anthropic
ANTHROPIC_MODEL=qwen3.5-plus
```

### C. Autoresearch 模式

```bash
# 自主迭代模式（单轮执行 + 外层循环重启）
./k8s-run.sh --env .env \
  --prompt agent/auto-iterate-prompt.txt \
  --auto-iterate \
  --name my-autoresearch \
  https://github.com/owner/repo
```

---

## 相关文档

- [LiteLLM Proxy 部署](./litellm-deployment.md) - LLM API 网关
- [Rancher Dashboard 部署](./rancher-dashboard.md) - 可视化管理界面
- [Rancher 安装指南](./rancher-installation.md) - 详细安装步骤