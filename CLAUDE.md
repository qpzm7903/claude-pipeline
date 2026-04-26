# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目三大中心

本仓库不是 pipeline，而是三层解耦的 AI 工程体系。任何修改前先确认涉及哪一层，避免跨层耦合。

### 中心一：Agent 镜像（`agent/`）

Docker 镜像层。提供 Claude / qwen-code 等 CLI agent 的运行环境，**不含**业务逻辑。

- **两层镜像结构**：`Dockerfile.<stack>-base`（编译/CLI 工具，构建慢、极少变）+ `Dockerfile.<stack>-agent`（仅 `lib/fmt_stream.py` + 修复 `.claude` 目录权限，每次迭代重建）
- **支持的栈**：`general`、`java`、`rust`
- **入口**：每个镜像**不**预置 ENTRYPOINT。容器启动命令由 K8s Job spec 显式指定（`bash /pipeline/run.sh`），`run.sh` 由 ConfigMap 注入

### 中心二：LiteLLM 模型网关（`k8s/litellm.yaml`）

K8s 命名空间 `litellm` 部署的统一 API 网关。所有 agent **只**通过它访问大模型。

- **核心价值**：透明协议转换 + 模型别名映射。Claude Code 写死的 `claude-sonnet-4-6` / `claude-opus-4-7` 通过 `model_list` 路由到底层 `glm-5.1` / `deepseek-chat` / `kimi-k2.6`，agent 代码无感
- **统一访问点**：`http://litellm.litellm.svc.cluster.local:4000`，`master_key` 从 K8s Secret 注入
- **部署脚本**：`k8s/setup-litellm.sh`；`k8s/secret.yaml`（不入库，参考 `secret.yaml.example`）保管各供应商 key

### 中心三：Job-Agent 一次性任务执行（`job-agent/`）—— 项目目的

本项目存在的根本原因：**用一次性 K8s Job 让 agent 持续迭代完成开发任务**。包括补单测、特性开发、重构、性能优化、bug 修复、SDD 流程等。

#### 目录结构

```
job-agent/
├── components/          # 通用组件
│   ├── run.sh           # 容器内启动脚本（CA 证书 / 镜像源 / git clone / agent 主循环）
│   ├── settings.json    # Claude CLI 设置（注入到 ~/.claude/settings.json）
│   └── skills/          # SKILL.md 集合（doc-sync / release-gate / repo-guard / ut-planner / ut-writer）
├── prompts/             # 可复用 prompt 片段库
│   ├── base-system.md           # 系统级约束（思维链、决策规则）
│   ├── base-observability.md    # .agent-progress.md 进度日志
│   ├── base-documentation.md    # CHANGELOG / ADR / README 规则
│   └── task-{ut-gen,feature-dev,refactor,perf-optimize,bug-fix}.md   # 5 类任务模板
├── tasks/<task-name>/   # 具体任务（自包含或引用 prompts/ 片段）
│   ├── job.yml          # K8s Job 定义 + 头部 `# assemble:` 元数据
│   └── prompt.md        # 任务专属 prompt
├── assemble.sh          # 唯一组装入口
├── dist/                # 生成的 all-in-one YAML（直接 kubectl apply）
└── ROADMAP.md           # 后续优化方向
```

#### 单一组装方案：`assemble.sh`

```bash
bash job-agent/assemble.sh job-agent/tasks/<name>/job.yml          # 生成 dist/<name>.yml
bash job-agent/assemble.sh job-agent/tasks/<name>/job.yml --apply  # 生成并 kubectl apply
bash job-agent/assemble.sh job-agent/tasks/<name>/job.yml -o out.yml
```

`tasks/<name>/job.yml` 头部用注释声明文件映射：

```yaml
# assemble: run.sh=components/run.sh
# assemble: prompt.md=prompts/base-system.md+prompts/base-observability.md+tasks/<name>/prompt.md
# assemble: settings.json=components/settings.json
# assemble: skills=components/skills
```

支持的键：

| 键 | 说明 |
|----|------|
| `run.sh` | 启动脚本路径（默认 `components/run.sh`） |
| `prompt.md` | 单文件，或 `A+B+C` 拼接多个 prompt 片段 |
| `settings.json` | Claude CLI 设置（默认 `components/settings.json`） |
| `skills=DIR` | 注入整个 skills 目录 |
| `skills=A,B` | 仅注入指定 skill（逗号分隔） |

#### 中心配置：`config/centers.yaml`

`assemble.sh` 在生成 dist YAML 时读取此文件，自动把**镜像、LiteLLM endpoint/Secret/默认模型、namespace、node** 注入到 Job spec。任务 yml 不再重复维护这些跨任务一致的字段。

- 镜像占位语法：`image: general:__from_centers__` → 按 `centers.image.general` 回填
- LiteLLM 环境变量：`ANTHROPIC_BASE_URL` / `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL` 在 task yml 未显式声明时从 `centers.litellm.*` 注入
- 显式声明 > centers.yaml > 不注入

#### 任务设计原则

- **可观测性**：agent 必须把进度写入仓库内的 `.agent-progress.md`，便于跨 session 续接
- **多次完成**：Job 默认 `completions: N`，每个 Pod 独立执行一轮，通过 git push 竞争协作
- **Prompt 分层**：`prompts/base-*.md`（共用约束）通过 `+` 拼到 `tasks/<name>/prompt.md` 前面
- **Skills 注入**：`assemble.sh` 通过 projected volume 把 `components/skills/<name>/SKILL.md` 挂到 `/skills/<name>/SKILL.md`

## 三层之间的关系

```
job-agent/tasks/*/job.yml           ← 你定义"做什么"
        │
        ├── 引用镜像 ──→ centers.image.<stack>     （中心一）
        ├── 调用模型 ──→ centers.litellm.base_url  （中心二）
        └── 部署目标 ──→ centers.kubernetes.namespace（中心三的载体）
```

任何修改的首问：**这是镜像层、网关层还是任务层？** 修错层会污染所有任务。

## 镜像构建

```bash
# General 栈（job-agent 默认用）
docker build -t general-claude-base:latest    -f agent/Dockerfile.general-base    ./agent/
docker build -t general-claude-pipeline:latest -f agent/Dockerfile.general-agent  ./agent/

# Java 栈
docker build -t java-claude-base:latest    -f agent/Dockerfile.java-base    ./agent/
docker build -t java-claude-pipeline:latest -f agent/Dockerfile.java-agent  ./agent/

# Rust 栈
docker build -t rust-claude:latest          -f agent/Dockerfile.rust-base   ./agent/
docker build -t rust-claude-pipeline:latest -f agent/Dockerfile.rust-agent  ./agent/

# Lint
docker run --rm -i hadolint/hadolint < agent/Dockerfile.general-agent
```

## 验证与 CI

```bash
pip install -r requirements.txt
python3 verify_local.py             # 全部
python3 verify_local.py --centers   # 仅 centers.yaml
python3 verify_local.py --assemble  # 仅 assemble.sh + run.sh
python3 verify_local.py --tasks     # 仅 tasks/<name>/ 自包含校验
```

`verify_local.py` 是关键字 + 结构检查。改动 assemble.sh / run.sh / tasks 布局时同步更新其检查列表。

- **CI**（`.github/workflows/ci.yml`）：每次 push/PR 跑 `verify_local.py` + 多 Dockerfile hadolint
- **Release**（`.github/workflows/release.yml`）：`v*.*.*` tag 触发，构建并推送 `general-claude-pipeline` 到 `ghcr.io/{repo}/general-claude-pipeline:{version}`

## 配置与密钥

- `config/centers.yaml`：三大中心的统一配置（镜像、LiteLLM、K8s 默认值）
- `.env`（不入库）、`.env.example`：本地开发用环境变量模板
- `k8s/secret.yaml`（不入库，参考 `secret.yaml.example`）：LiteLLM 用的各供应商 key

## 关键设计决策

- **Agent 自主**：`components/run.sh` 是**纯启动器**，所有业务逻辑写在 `prompts/` 与 `tasks/<name>/prompt.md`
- **Prompt 即合约**：任务规范靠 prompt 传递，不靠 shell 编排
- **网关收敛**：所有模型调用走 LiteLLM，禁止 agent 直连各供应商 endpoint
- **单一组装入口**：`assemble.sh` 是**唯一**的 task → all-in-one YAML 通道
- **中心配置集中**：跨任务一致的字段（镜像、LiteLLM、namespace）只在 `config/centers.yaml` 维护一次
