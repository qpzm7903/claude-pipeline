# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands

```bash
# Install dependencies
pip install -r requirements.txt

# Run local verification tests (no Docker needed)
python3 verify_local.py                    # 全部验证
python3 verify_local.py --test-prompt      # entrypoint 工作流完整性
python3 verify_local.py --test-config      # config.yaml 结构验证

# Start agent containers
./run.sh https://github.com/user/repo      # 为单个 repo 启动容器
./run.sh                                    # 批量启动 repos.yaml 中所有 enabled repo

# 使用国内代理
ANTHROPIC_BASE_URL=https://dashscope.aliyuncs.com/apps/anthropic \
ANTHROPIC_MODEL=qwen3.5-plus \
./run.sh https://github.com/user/repo

# Build images（两层结构：base 镜像很少变，agent 镜像每次迭代只需重建 agent 层）
docker build -t claude-pipeline-base:latest -f agent/Dockerfile.base ./agent/
docker build -t claude-pipeline-agent:latest ./agent/

# Lint the Dockerfile
docker run --rm -i hadolint/hadolint < agent/Dockerfile

# Kubernetes mode
./k8s-run.sh                               # 为所有 enabled repo 创建/更新 CronJob
./k8s-run.sh https://github.com/owner/repo # 单个 repo
./k8s-run.sh --status                      # 查看 CronJob、Job、Pod 状态
./k8s-run.sh --logs                        # 查看最近 Pod 日志
./k8s-run.sh --logs -f                     # 实时跟踪
./k8s-run.sh --update-secret               # 换 token 后同步 K8s Secret
./k8s-run.sh --delete                      # 删除所有 CronJob
```

## Architecture

极简单进程 pipeline — 无需编排器：

**`run.sh`** (host machine, bash):
- Reads `config/repos.yaml`, starts one Docker container per enabled repo
- Passes env vars (API key, model, git token) into each container
- Containers are fully autonomous; host has no further involvement

**Agent** (inside Docker container):
- `agent/entrypoint.sh` — 2 步：git clone → Claude 自主执行（含代码提交、推送和创建 PR）
- `agent/container-CLAUDE.md` — 容器内 Claude 的通用行为约束（提交规范、推送规则等）

**核心设计原则**：Claude 全权自主决策。`entrypoint.sh` 只是启动器，不编排任何业务逻辑。所有规范（BMAD 工作流、代码质量、版本发布等）通过目标仓库的 `CLAUDE.md` 传递给 Claude。

**Concurrency via Git**: Multiple containers can run against the same repo simultaneously. Each container races to `git push`. Only the successful fast-forward push wins.

## Key Design Decisions

**Autonomous agent**: The bash entrypoint is a minimal launcher. Claude reads the target repo's `CLAUDE.md` and decides what to do autonomously. Do NOT add business logic to `entrypoint.sh`.

**Target repo CLAUDE.md is the contract**: All development rules, workflow requirements, and quality standards should be defined in the target repository's `CLAUDE.md`, not in the pipeline infrastructure. See `example_repo/CLAUDE.md` for a template.

**Two-image build**: `Dockerfile.base` (Rust, Node.js, claude CLI — slow to build, rarely changes) + `Dockerfile` (entrypoint only — fast, rebuilt on every code change).

**Environment variable priority** (high → low): host env var → `config/config.yaml` → built-in default.

**API key compatibility**: Supports both `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`. Model supports both `ANTHROPIC_MODEL` and `CLAUDE_MODEL`.

**DashScope proxy**: Set `ANTHROPIC_BASE_URL=https://dashscope.aliyuncs.com/apps/anthropic` and `ANTHROPIC_MODEL=qwen3.5-plus`. Do not append `/v1`.

## Configuration

- `config/config.yaml` — docker image name, anthropic base_url/model, git author, k8s settings
- `config/repos.yaml` — list of repos to monitor (`enabled: true/false`)
- `.env` — secrets only (never committed): `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`, `GIT_TOKEN`

## CI/CD

- **CI** (`.github/workflows/ci.yml`): runs `verify_local.py` + hadolint on every push/PR to main
- **Release** (`.github/workflows/release.yml`): triggered by `v*.*.*` tags; builds + pushes Docker image to `ghcr.io/{repo}/agent:{version}`, creates GitHub Release

## Modifying entrypoint.sh

After any change, always run:
```bash
bash -n agent/entrypoint.sh   # syntax check
python3 verify_local.py       # structural check
```

`verify_local.py` checks for the presence of specific keywords. If you rename or remove a function/phase, update the `checks` list in `verify_local.py` accordingly.
