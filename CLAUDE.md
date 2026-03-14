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

# Build the agent Docker image
docker build -t claude-pipeline-agent:latest ./agent/

# Lint the Dockerfile
docker run --rm -i hadolint/hadolint < agent/Dockerfile
```

## Architecture

The system is a single-process pipeline — no orchestrator needed:

**`run.sh`** (host machine, bash):
- Reads `config/repos.yaml`, starts one Docker container per enabled repo
- Passes env vars (API key, model, git token) into each container
- Containers are fully autonomous; host has no further involvement

**Agent** (inside Docker container, per task):
- `agent/entrypoint.sh` — 6 steps: git clone → **BMAD phase loop / Git atomic claim (step 1.5)** → invoke Claude → **independent review (step 2.5)** → git push + PR → **PR feedback loop (step 4)**
- `agent/create_pr.py` — GitHub REST API PR creation; reads `review_result.json` for PR body; creates draft PR if verdict ≠ "pass"

**BMAD phase loop** (step 1.5): A `while` state machine cycles through `discover→planning→create-story→claim→done` within a single container run. No external restart needed. `MAX_PHASE_LOOPS=5` prevents infinite loops.

**Independent review** (step 2.5): A separate Claude invocation reviews the diff with zero implementation context — eliminates "grading your own exam" bias. Followed by `append_dev_log()` for BMAD projects.

**PR feedback loop** (step 4): After PR creation, waits for CI status (up to 10min) and checks for review comments. If issues found, Claude auto-fixes and pushes (up to 2 retries).

**Concurrency via Git**: Multiple containers can run against the same repo simultaneously.
Each container races to `git push` a `[-]` marker for one task. Only the successful push wins the task (Git fast-forward rejection = distributed lock). No SQLite, no coordinator.

**Data flow**: Container receives `REPO_URL` env var → clones repo → finds first `[ ]` task in `plan.md` → claims it → Claude executes → marks `[x]` → pushes branch + opens PR.

## Key Design Decisions

**Autonomous agent**: The bash entrypoint is intentionally minimal. Claude installs any needed toolchain (Rust, Node.js, etc.) autonomously. Do NOT add language-specific logic to `entrypoint.sh`.

**Environment variable priority** (high → low): host env var → `config/config.yaml` → built-in default. `run.sh` implements this for docker/anthropic/git settings.

**API key compatibility**: Supports both `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` (same key, different names). Model supports both `ANTHROPIC_MODEL` and `CLAUDE_MODEL`.

**DashScope proxy**: Set `ANTHROPIC_BASE_URL=https://dashscope.aliyuncs.com/apps/anthropic` and `ANTHROPIC_MODEL=qwen3.5-plus`. Do not append `/v1` — the endpoint handles routing internally.

**Claude CLI invocation**: Always uses `--dangerously-skip-permissions --print` with heredoc stdin. The claude CLI rejects `--dangerously-skip-permissions` when run as root, so the Dockerfile creates a non-root `pipeline` user.

**Task state machine** (in plan.md):
- `[ ]` — pending (available to claim)
- `[-]` — in progress (claimed by a container)
- `[x]` — completed

## Configuration

- `config/config.yaml` — docker image name, anthropic base_url/model, git author
- `config/repos.yaml` — list of repos to monitor
- `.env` — secrets only (never committed): `ANTHROPIC_API_KEY`, `GIT_TOKEN`

## Task Format (plan.md)

```markdown
- [ ] id:001 Task title
  spec: ./specs/task.md
  priority: high
```

Tasks without explicit `id:XXX` get a stable ID from the first 8 chars of the line's md5. Completed tasks `[x]` and in-progress `[-]` tasks are skipped.

## CI/CD

- **CI** (`.github/workflows/ci.yml`): runs `verify_local.py` + hadolint on every push/PR to main
- **Release** (`.github/workflows/release.yml`): triggered by `v*.*.*` tags; builds + pushes Docker image to `ghcr.io/{repo}/agent:{version}`, creates GitHub Release with source tarball
