# Claude Pipeline

AI 驱动的自动化开发流水线。定时扫描仓库任务，为每个任务启动独立 Docker 容器，由 Claude 自主完成 TDD 开发并提交 PR。

```
[plan.md / GitHub Issues]
        ↓ 定时扫描
[Orchestrator] → [SQLite 任务队列]
        ↓ 每任务独立容器
[Docker Container]
  ├── git clone
  ├── Claude 自主执行（TDD → 实现 → 审查）
  ├── git push
  └── 自动创建 PR
```

## 快速开始

### 1. 配置环境变量

```bash
cp .env.example .env
# 编辑 .env 填入：
# ANTHROPIC_API_KEY    Anthropic / 兼容代理的 API Key
# ANTHROPIC_BASE_URL   自定义 API 地址（可选）
# ANTHROPIC_MODEL      模型名（可选，默认使用代理路由）
# GIT_TOKEN            GitHub Personal Access Token
```

### 2. 配置仓库

编辑 `config/repos.yaml`，添加要监控的仓库：

```yaml
repos:
  - name: "my-project"
    url: "https://github.com/owner/repo"
    task_source: "plan_md"    # plan_md | github_issues
    test_command: "pytest"
    language: "python"
    enabled: true
```

### 3. 在目标仓库添加任务

`plan.md` 格式：

```markdown
## Tasks

- [ ] id:001 实现用户认证 API
  spec: ./specs/auth.md
  priority: high

- [x] id:002 已完成的任务
```

### 4. 构建并运行

```bash
# 构建 Agent 镜像
docker build -t claude-pipeline-agent:latest ./agent/

# 安装依赖
pip install -r requirements.txt

# 验证本地逻辑
python3 verify_local.py

# 启动流水线（dry-run 模式，只扫描不执行）
python3 -m orchestrator.main --dry-run --once

# 正式运行
python3 -m orchestrator.main
```

## 环境变量参考

| 变量 | 必填 | 说明 |
|------|------|------|
| `ANTHROPIC_API_KEY` | ✅ | API Key（也支持 `ANTHROPIC_AUTH_TOKEN`） |
| `ANTHROPIC_BASE_URL` | 可选 | 自定义 API 地址，如 DashScope 代理 |
| `ANTHROPIC_MODEL` | 可选 | 模型名，如 `qwen3.5-plus` |
| `GIT_TOKEN` | ✅ | GitHub PAT（需要 `repo` + `pull_requests` 权限） |
| `PROXY_FALLBACK_MODEL` | 可选 | 非 claude-* 模型时的回退模型名 |

## 项目结构

```
├── orchestrator/
│   ├── main.py               # 主调度循环
│   ├── task_scanner.py       # 扫描 plan.md / GitHub Issues
│   ├── task_queue.py         # SQLite 状态机
│   └── container_manager.py  # Docker 容器管理
├── agent/
│   ├── Dockerfile            # Agent 镜像（Node + Python + git）
│   ├── entrypoint.sh         # 克隆 → Claude 自主执行 → 推送
│   └── create_pr.py          # 自动创建 GitHub PR
├── config/
│   ├── config.yaml           # 全局配置
│   └── repos.yaml            # 仓库列表
└── example_repo/             # 本地测试用示例仓库
```

## 任务状态机

```
pending → running → completed
              ↓
           failed
```

## 使用代理（DashScope 示例）

```bash
ANTHROPIC_BASE_URL=https://dashscope.aliyuncs.com/apps/anthropic
ANTHROPIC_API_KEY=your-dashscope-key
ANTHROPIC_MODEL=qwen3.5-plus
```

## License

MIT
