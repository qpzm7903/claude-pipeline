# Claude Pipeline

AI 驱动的自动化开发流水线。定时扫描仓库任务，为每个任务启动独立容器，由 Claude 自主完成开发并提交 PR。

```
[plan.md / BMAD Stories]
        ↓ 定时触发（Docker / Kubernetes CronJob）
[Agent Container]
  ├── git clone
  ├── Git 原子抢占（分布式锁，多容器安全并发）
  ├── Claude 自主执行（TDD → 实现 → 审查）
  ├── git push
  └── 自动创建 PR
```

## 快速开始

### 1. 配置环境变量

```bash
cp .env.example .env
# 编辑 .env 填入：
# ANTHROPIC_AUTH_TOKEN   API Key（或 ANTHROPIC_API_KEY）
# ANTHROPIC_BASE_URL     自定义 API 地址（可选，如 DashScope 代理）
# ANTHROPIC_MODEL        模型名（可选，如 qwen3.5-plus）
# GIT_TOKEN              GitHub Personal Access Token
```

### 2. 配置仓库

编辑 `config/repos.yaml`，添加要监控的仓库：

```yaml
repos:
  - name: "my-project"
    url: "https://github.com/owner/repo"
    enabled: true
```

### 3. 构建 Agent 镜像

```bash
# 先构建基础镜像（预装 Rust、Node.js、claude CLI）
docker build -t claude-pipeline-base:latest -f agent/Dockerfile.base ./agent/

# 再构建 Agent 镜像
docker build -t claude-pipeline-agent:latest ./agent/
```

### 4. 运行

#### Docker 模式（单次执行）

```bash
# 单个仓库
./run.sh https://github.com/owner/repo

# 批量执行 repos.yaml 中所有 enabled 仓库
./run.sh

# 使用代理
ANTHROPIC_BASE_URL=https://dashscope.aliyuncs.com/apps/anthropic \
ANTHROPIC_MODEL=qwen3.5-plus \
./run.sh https://github.com/owner/repo
```

#### Kubernetes 模式（定时自动触发）

```bash
# 1. 创建 Secret
cp k8s/secret.yaml.example k8s/secret.yaml
kubectl apply -f k8s/secret.yaml

# 或者直接从 .env 生成（推荐）
./k8s-run.sh --update-secret

# 2. 部署 CronJob
./k8s-run.sh                                     # 所有 enabled 仓库
./k8s-run.sh https://github.com/owner/repo       # 单个仓库

# 3. 常用操作
./k8s-run.sh --status                            # 查看状态
./k8s-run.sh --logs                              # 查看最近 Pod 日志
./k8s-run.sh --delete                            # 删除所有 CronJob
./k8s-run.sh --update-secret                     # 换 token 后同步 Secret
./k8s-run.sh --env .env.prod                     # 指定 env 文件
```

## 环境变量参考

| 变量 | 必填 | 说明 |
|------|------|------|
| `ANTHROPIC_AUTH_TOKEN` | ✅ | API Key（也支持 `ANTHROPIC_API_KEY`） |
| `ANTHROPIC_BASE_URL` | 可选 | 自定义 API 地址，如 DashScope 代理 |
| `ANTHROPIC_MODEL` | 可选 | 模型名，如 `qwen3.5-plus` |
| `GIT_TOKEN` | ✅ | GitHub PAT（需要 `repo` + `pull_requests` 权限） |

## 项目结构

```
├── agent/
│   ├── Dockerfile.base       # 基础镜像（Rust、Node.js、claude CLI）
│   ├── Dockerfile            # Agent 镜像（基于 base，追加 entrypoint）
│   ├── entrypoint.sh         # 克隆 → 认领任务 → Claude 执行 → 推送
│   └── create_pr.py          # 自动创建 GitHub PR
├── k8s/
│   ├── namespace.yaml        # K8s namespace
│   ├── rbac.yaml             # ServiceAccount
│   ├── cronjob-template.yaml # CronJob 模板（含占位符）
│   ├── secret.yaml.example   # Secret 示例
│   └── render_and_apply.py   # 模板渲染 + kubectl apply
├── config/
│   ├── config.yaml           # 全局配置（docker、anthropic、git、kubernetes）
│   └── repos.yaml            # 仓库列表
├── run.sh                    # Docker 模式入口
├── k8s-run.sh                # Kubernetes 模式入口
└── verify_local.py           # 本地验证脚本
```

## 并发安全

多个容器可同时运行，通过 **Git 原子 push** 实现分布式锁：

- 每个容器 `git push` 一个 `[-]` 标记认领任务
- 只有 fast-forward push 成功的容器才能执行该任务
- 其他容器收到拒绝后自动跳过，无需协调器

Kubernetes 模式默认 `concurrencyPolicy: Forbid`，上一个 Job 未结束时跳过本次触发。

## 使用代理（DashScope 示例）

```bash
ANTHROPIC_BASE_URL=https://dashscope.aliyuncs.com/apps/anthropic
ANTHROPIC_AUTH_TOKEN=your-dashscope-key
ANTHROPIC_MODEL=qwen3.5-plus
```

## 本地验证

```bash
pip install -r requirements.txt
python3 verify_local.py           # 完整验证
python3 verify_local.py --test-k8s    # 仅验证 K8s 清单文件
```

## License

MIT
