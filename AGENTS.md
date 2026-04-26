# Repository Guidelines

## Project Structure & Module Organization

This repository has three decoupled centers. `agent/` contains Docker images for CLI agent runtimes and must not include task business logic. `k8s/` contains Kubernetes resources, including LiteLLM deployment, setup scripts, RBAC, namespaces, and smoke tests. `job-agent/` contains one-shot task execution: reusable `components/`, prompt fragments in `prompts/`, task definitions in `tasks/<task-name>/`, and generated YAML in `dist/`. Shared defaults live in `config/centers.yaml`. Documentation is in `docs/`; local structural checks are implemented in `verify_local.py`.

## Build, Test, and Development Commands

Install Python dependencies before validation:

```bash
pip install -r requirements.txt
python3 verify_local.py
```

Use scoped checks while iterating:

```bash
python3 verify_local.py --centers
python3 verify_local.py --assemble
python3 verify_local.py --tasks
```

Assemble and optionally deploy a task:

```bash
bash job-agent/assemble.sh job-agent/tasks/<name>/job.yml
bash job-agent/assemble.sh job-agent/tasks/<name>/job.yml --apply
```

Build image layers from `agent/` with explicit Dockerfiles, for example `docker build -t general-claude-pipeline:latest -f agent/Dockerfile.general-agent ./agent/`. Lint Dockerfiles with hadolint before PRs.

## Coding Style & Naming Conventions

Keep the three centers separated: image changes in `agent/`, gateway/K8s changes in `k8s/`, and task orchestration in `job-agent/`. Prefer YAML with two-space indentation. Name tasks with lowercase kebab-case under `job-agent/tasks/<task-name>/`, with `job.yml` and `prompt.md`. Use `# assemble:` comments in task YAML for injected files, and keep cross-task defaults in `config/centers.yaml` instead of duplicating them.

## Testing Guidelines

`verify_local.py` is the primary test suite and CI gate. Run the full check before pushing, and update it when changing `assemble.sh`, `components/run.sh`, task layout rules, or `centers.yaml` semantics. CI also runs hadolint across all Dockerfiles in `agent/`.

## Commit & Pull Request Guidelines

Recent history uses short imperative commits, often with conventional prefixes such as `feat(job-agent): ...`, `feat(k8s): ...`, `feat(agent): ...`, `chore(k8s): ...`, and `docs: ...`. Follow that style and scope commits by center. PRs should describe the affected center, list validation commands run, mention any required Kubernetes or secret changes, and include generated YAML impacts when task assembly changes.

## Security & Configuration Tips

Do not commit live secrets. Use `.env.example` for local environment templates and `k8s/secret.yaml.example` for LiteLLM provider keys. `k8s/secret.yaml` and `.env` are local-only. All model access should route through LiteLLM; do not add direct provider endpoints to agent task logic.
