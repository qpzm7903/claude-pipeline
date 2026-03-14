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

# ⚠️  无 base 镜像时用 docker commit 打补丁（必须加 --change，否则 ENTRYPOINT/USER 丢失）
# docker commit --change 'USER pipeline' \
#               --change 'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]' \
#               --change 'CMD []' \
#               <container_id> claude-pipeline-agent:latest

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

The system is a single-process pipeline — no orchestrator needed:

**`run.sh`** (host machine, bash):
- Reads `config/repos.yaml`, starts one Docker container per enabled repo
- Passes env vars (API key, model, git token) into each container
- Containers are fully autonomous; host has no further involvement

**Agent** (inside Docker container, per task):
- `agent/entrypoint.sh` — 6 steps: git clone → **BMAD phase loop / Git atomic claim (step 1.5)** → invoke Claude → **dev-log + independent review (step 2.5)** → git push + PR → **PR feedback loop (step 4)**
- `agent/create_pr.py` — GitHub REST API PR creation; reads `review_result.json` for PR body; creates draft PR if verdict ≠ "pass"
- `agent/AGENT_RULES.md` — injected into every Claude prompt as mandatory constraints (termination signals, git safety, review isolation)

**BMAD phase loop** (step 1.5): A `while` state machine cycles through phases within a single container run. `MAX_PHASE_LOOPS=5` prevents infinite loops.

| Phase | Trigger | Output |
|-------|---------|--------|
| `discover` | every run | routes to next phase; **checks `pipeline-ci-failure` issues first** |
| `ci-fix` | open `pipeline-ci-failure` issue exists | Claude fixes CI, closes issue |
| `planning` | no sprint-status.yaml | generates PRD + architecture + sprint-status.yaml |
| `create-story` | backlog stories exist | promotes one story to ready-for-dev |
| `claim` | in-progress or ready-for-dev story found | claims one task within that story |
| `done` | terminal state | container exits |

**Story-level CI tracking** (step 3.5): Only runs when `STORY_COMPLETE=true` (all tasks in the story file are `[x]`). Creates a `story-{KEY}-{timestamp}` tag → waits for GitHub Actions CI (10 min max) → on failure calls `create_ci_failure_issue()` which opens a GitHub issue labeled `pipeline-ci-failure`. The next container's `discover` phase picks this issue up as highest priority.

**Independent review** (step 2.5): A separate Claude invocation reviews the diff with zero implementation context — eliminates "grading your own exam" bias. Followed by `append_dev_log()` for BMAD projects.

**PR feedback loop** (step 4): After PR creation, waits for CI status (up to 10min) and checks for review comments. If issues found, Claude auto-fixes and pushes (up to 2 retries).

**Concurrency via Git**: Multiple containers can run against the same repo simultaneously. Each container races to `git push` a `[-]` marker. Only the successful fast-forward push wins the task. No SQLite, no coordinator.

## Key Design Decisions

**Autonomous agent**: The bash entrypoint is intentionally minimal. Claude installs any needed toolchain autonomously. Do NOT add language-specific logic to `entrypoint.sh`.

**AGENT_RULES.md is the contract**: `agent/AGENT_RULES.md` defines termination signals (`PIPELINE_COMPLETE`, `REVIEW_COMPLETE`, etc.), the `/tmp/agent_action.json` discover protocol, and hard constraints (no `git push` from Claude, no self-review). Changes here affect all Claude invocations inside the container.

**Task-level granularity**: Each container run executes exactly one task from a story. The `[-]` → `[x]` transition within the story file is done by Claude; the `sprint-status.yaml` story-level status update (`in-progress` → `review`) only happens when all tasks in that story are `[x]`.

**Two-image build**: `Dockerfile.base` (Rust, Node.js, claude CLI — slow to build, rarely changes) + `Dockerfile` (entrypoint only — fast, rebuilt on every code change). The K8s `imagePullPolicy: Never` uses the local image; change to `Always` for remote registry workflows.

**Environment variable priority** (high → low): host env var → `config/config.yaml` → built-in default. `run.sh` implements this for docker/anthropic/git settings.

**API key compatibility**: Supports both `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` (same key, different names). Model supports both `ANTHROPIC_MODEL` and `CLAUDE_MODEL`.

**DashScope proxy**: Set `ANTHROPIC_BASE_URL=https://dashscope.aliyuncs.com/apps/anthropic` and `ANTHROPIC_MODEL=qwen3.5-plus`. Do not append `/v1`.

**Task state machine** (in plan.md for non-BMAD, story file for BMAD):
- `[ ]` — pending (available to claim)
- `[-]` — in progress (claimed by a container)
- `[x]` — completed

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
