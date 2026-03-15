# Claude Pipeline

AI 驱动的自动化开发流水线。定时扫描仓库，启动独立容器，由 Claude 全权自主完成开发并推送代码。

```
[CLAUDE.md 规范 + 仓库代码]
        ↓ 定时触发（Docker / Kubernetes CronJob）
[Agent Container]
  ├── git clone（带重试）
  └── Claude 自主执行（读取 CLAUDE.md → 实施 → 提交 → 推送 → 创建 PR）
```

## 核心理念

**Claude 全权自主决策**。`entrypoint.sh` 只是一个约 200 行的启动器，不编排任何业务逻辑。所有规范（BMAD 工作流、代码质量、版本发布等）通过目标仓库的 `CLAUDE.md` 传递给 Claude。

这比复杂的 bash 状态机效果更好，因为 AI 的自主决策能力优于预设的固定流程。

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

### 2. 在目标仓库中创建 CLAUDE.md

将 `example_repo/CLAUDE.md` 复制到目标仓库根目录，按需修改：

```bash
cp example_repo/CLAUDE.md /path/to/your/repo/CLAUDE.md
```

### 3. 配置仓库列表

编辑 `config/repos.yaml`，添加要监控的仓库：

```yaml
repos:
  - name: "my-project"
    url: "https://github.com/owner/repo"
    enabled: true
```

### 4. 构建 Agent 镜像

镜像分两层，基础镜像（Rust、Node.js、claude CLI）很少变化，日常迭代只需重建 Agent 层：

```bash
# 首次或 claude CLI 版本升级时才需要重建 base
docker build -t claude-pipeline-base:latest -f agent/Dockerfile.base ./agent/

# 日常代码变更只需重建 agent 层（秒级完成）
docker build -t claude-pipeline-agent:latest ./agent/
```

### 5. 运行

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
./k8s-run.sh --update-secret

# 2. 部署 CronJob
./k8s-run.sh                                     # 所有 enabled 仓库
./k8s-run.sh https://github.com/owner/repo       # 单个仓库

# 3. 常用操作
./k8s-run.sh --status                            # 查看状态
./k8s-run.sh --logs                              # 查看最近 Pod 日志
./k8s-run.sh --delete                            # 删除所有 CronJob
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
│   ├── entrypoint.sh         # 克隆 → Claude 自主执行（含提交、推送和 PR）
│   ├── container-CLAUDE.md   # 容器内 Claude 通用规则（提交规范、推送规则等）
├── example_repo/
│   └── CLAUDE.md             # 目标仓库 CLAUDE.md 模板（复制到你的仓库使用）
├── k8s/
│   ├── namespace.yaml        # K8s namespace
│   ├── rbac.yaml             # ServiceAccount
│   ├── cronjob-template.yaml # CronJob 模板
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

- 只有 fast-forward push 成功的容器才能推送
- 其他容器收到拒绝后自动跳过

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
python3 verify_local.py           # 完整验证（语法 + 结构 + K8s 清单）
```

## License

MIT
