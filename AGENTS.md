# Repository Guidelines

## Project Structure & Module Organization

- `agent/` contains the runtime image assets: `entrypoint.sh`, prompt templates, Dockerfiles, and reusable helpers in `agent/lib/`.
- `config/` stores local defaults in `config.yaml` and monitored repositories in `repos.yaml`.
- `k8s/` holds CronJob templates, RBAC/namespace manifests, secret examples, and `render_and_apply.py`.
- `docs/` contains deployment guides and ADRs. `example_repo/` shows the expected shape of a target repository (`CLAUDE.md`, `plan.md`, `specs/`).
- Treat `.env*`, `logs/`, `pipeline.db`, and `k8s/secret.yaml` as local runtime artifacts, not source files.

## Build, Test, and Development Commands

- `pip install -r requirements.txt` installs the Python helpers used by local verification and K8s rendering.
- `python3 verify_local.py` runs the full structural validation suite.
- `python3 verify_local.py --test-prompt` or `--test-config` narrows checks while iterating on one area.
- `./run.sh https://github.com/owner/repo` launches a single Docker-backed pipeline run. `./run.sh` without arguments reads enabled entries from `config/repos.yaml`.
- `./k8s-run.sh --status` inspects CronJobs, Jobs, and Pods. `./k8s-run.sh --update-secret` refreshes cluster secrets from local env values.
- `./build-images.sh rust latest` rebuilds the Rust-based images. Use `general` or `all` for other image sets.

## Coding Style & Naming Conventions

- Follow the existing Bash-first style: `#!/usr/bin/env bash`, `set -euo pipefail`, small functions, and uppercase env vars.
- Use 4-space indentation in Python and YAML. Prefer `pathlib`, straightforward CLI parsing, and `snake_case` function names.
- Keep filenames descriptive and consistent with the current patterns, for example `Dockerfile.rust-agent`, `setup-pipeline.sh`, and ADR files like `0001-fmt-stream-decoupling.md`.
- Preserve the architecture boundary: keep `agent/entrypoint.sh` thin. Policy and workflow behavior belong in prompt files or the target repo’s `CLAUDE.md`.

## Testing Guidelines

- There is no separate unit-test directory yet; the required baseline is `python3 verify_local.py`.
- After shell changes, run `bash -n run.sh agent/entrypoint.sh k8s-run.sh`.
- After Dockerfile edits, run `docker run --rm -i hadolint/hadolint < agent/Dockerfile.rust-agent`.
- For `k8s/` changes, validate against a configured cluster when possible, at minimum with `./k8s-run.sh --status`.

## Commit & Pull Request Guidelines

- Match the repo’s Conventional Commit style: `feat(agent): ...`, `refactor: ...`, `build: ...`, `docs: ...`, `chore(workflow): ...`.
- Keep each commit focused on one concern and include the affected area when useful.
- PRs should summarize the behavior change, list validation commands run, and note any required image rebuilds, secret updates, or rollout steps.
- Use screenshots only for documentation or dashboard changes; for runtime changes, include relevant command output or log snippets instead.
