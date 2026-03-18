#!/usr/bin/env python3
"""
render_and_apply.py - 渲染 CronJob 模板并应用到 Kubernetes

用法:
  python3 k8s/render_and_apply.py                          # 为所有 enabled repo 创建/更新 CronJob
  python3 k8s/render_and_apply.py https://github.com/u/r  # 单个 repo
"""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    print("❌ 需要安装 PyYAML: pip install pyyaml")
    sys.exit(1)

SCRIPT_DIR = Path(__file__).parent
PROJECT_DIR = SCRIPT_DIR.parent
CONFIG_DIR = PROJECT_DIR / "config"
TEMPLATE_PATH = SCRIPT_DIR / "cronjob-template.yaml"


def slug(url: str) -> str:
    """将 GitHub URL 转换为合法的 K8s resource name（max 52 chars）。

    例: https://github.com/foo/my-repo → foo-my-repo
    """
    # 提取 owner/repo 部分
    match = re.search(r"github\.com[/:]([^/]+)/([^/\s]+?)(?:\.git)?$", url)
    if match:
        owner, repo = match.group(1), match.group(2)
        raw = f"{owner}-{repo}"
    else:
        raw = url.split("//")[-1].replace("/", "-")

    # 过滤非法字符，转小写
    cleaned = re.sub(r"[^a-z0-9-]", "-", raw.lower())
    # 合并连续连字符
    cleaned = re.sub(r"-+", "-", cleaned).strip("-")
    return cleaned[:52]


def load_config() -> dict:
    """读取 config/config.yaml。"""
    cfg_path = CONFIG_DIR / "config.yaml"
    if not cfg_path.exists():
        print(f"❌ 配置文件不存在: {cfg_path}")
        sys.exit(1)
    return yaml.safe_load(cfg_path.read_text()) or {}


def load_repos() -> list[dict]:
    """读取 config/repos.yaml，返回 enabled 的 repo 列表。"""
    repos_path = CONFIG_DIR / "repos.yaml"
    if not repos_path.exists():
        print(f"❌ repos 配置不存在: {repos_path}")
        sys.exit(1)
    data = yaml.safe_load(repos_path.read_text()) or {}
    repos = data.get("repos", [])
    return [r for r in repos if r.get("enabled", True)]


def check_secret_exists(namespace: str) -> bool:
    """检查 claude-pipeline-secrets Secret 是否已创建。"""
    result = subprocess.run(
        ["kubectl", "get", "secret", "claude-pipeline-secrets", "-n", namespace],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0


def render_template(repo_url: str, cfg: dict) -> str:
    """渲染 CronJob 模板，替换所有 {PLACEHOLDER}。"""
    template = TEMPLATE_PATH.read_text()

    k8s_cfg = cfg.get("kubernetes", {})
    anthropic_cfg = cfg.get("anthropic", {})
    git_cfg = cfg.get("git", {})
    docker_cfg = cfg.get("docker", {})

    model = (
        os.environ.get("ANTHROPIC_MODEL")
        or os.environ.get("CLAUDE_MODEL")
        or anthropic_cfg.get("model", "claude-opus-4-5-20251001")
    )
    base_url = (
        os.environ.get("ANTHROPIC_BASE_URL")
        or anthropic_cfg.get("base_url", "")
        or ""
    )

    job_deadline = k8s_cfg.get("job_deadline_seconds", 0)

    replacements = {
        "{REPO_SLUG}": slug(repo_url),
        "{REPO_URL}": repo_url,
        "{SCHEDULE}": k8s_cfg.get("schedule", "*/5 * * * *"),
        "{IMAGE}": docker_cfg.get("image", "claude-pipeline-agent:latest"),
        "{IMAGE_PULL_POLICY}": k8s_cfg.get("image_pull_policy", "Never"),
        "{MODEL}": model,
        "{ANTHROPIC_BASE_URL}": base_url,
        "{GIT_AUTHOR_NAME}": git_cfg.get("author_name", "Claude Pipeline Bot"),
        "{GIT_AUTHOR_EMAIL}": git_cfg.get("author_email", "pipeline@claude.ai"),
        "{JOB_DEADLINE}": str(job_deadline),
    }

    result = template
    for placeholder, value in replacements.items():
        result = result.replace(placeholder, value)

    # job_deadline_seconds=0 表示不限制运行时间，移除 activeDeadlineSeconds 行
    if job_deadline <= 0:
        result = "\n".join(
            line for line in result.splitlines()
            if "activeDeadlineSeconds" not in line
        )

    return result


def apply_manifest(content: str, display_name: str) -> bool:
    """写临时文件并 kubectl apply（create-or-update 幂等）。"""
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".yaml", prefix="claude-pipeline-", delete=False
    ) as f:
        f.write(content)
        tmp_path = f.name

    try:
        result = subprocess.run(
            ["kubectl", "apply", "-f", tmp_path],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            print(f"  ✅ {display_name}: {result.stdout.strip()}")
            return True
        else:
            print(f"  ❌ {display_name}: {result.stderr.strip()}")
            return False
    finally:
        os.unlink(tmp_path)


def render_inline(repo_url: str, cfg: dict, name_override: str | None = None) -> str:
    """生成 CronJob YAML，所有 env 直接写入 pod（不用 Secret）。

    从当前 os.environ 读取全量配置，适合通过 --env 加载的自定义配置文件场景。
    """
    k8s_cfg = cfg.get("kubernetes", {})
    git_cfg = cfg.get("git", {})
    docker_cfg = cfg.get("docker", {})

    # 优先从 env 读取 repo URL
    repo_url_final = os.environ.get("GIT_REPO_URL") or repo_url

    # CronJob 名称：--name 优先，否则用 repo slug
    cj_slug = name_override or slug(repo_url_final)
    cj_name = f"claude-pipeline-{cj_slug}"

    # 收集所有需要注入的 env var（保留 .env 文件中所有已知键）
    env_keys = [
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_MODEL",
        "CLAUDE_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "GIT_TOKEN",
        "GITHUB_TOKEN",
        "GH_TOKEN",
        "CLAUDE_PROMPT_FILE",    # 内置 prompt 文件路径（如 /agent/repo-prompt-driven.txt）
        "CLAUDE_PROMPT",         # 内联 prompt 字符串
        "AUTO_ITERATE",          # true = autoresearch 单轮循环模式
        "MAX_ITERATIONS",        # 最大迭代次数（0 = 无限）
        "ITER_COOLDOWN",         # 迭代间隔秒数
        "ROUND_TIMEOUT",         # 每轮最大执行秒数（默认 1800）
        "MAX_NOCHANGE",          # 连续无变更退出阈值（默认 3）
    ]
    env_entries = [
        {"name": "REPO_URL", "value": repo_url_final},
        {"name": "GIT_AUTHOR_NAME", "value": git_cfg.get("author_name", "Claude Pipeline Bot")},
        {"name": "GIT_AUTHOR_EMAIL", "value": git_cfg.get("author_email", "pipeline@claude.ai")},
    ]
    seen = {"REPO_URL", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL"}
    for key in env_keys:
        val = os.environ.get(key)
        if val and key not in seen:
            env_entries.append({"name": key, "value": val})
            seen.add(key)

    # 自动补全别名（保证 entrypoint.sh 两种变量名都能读到）
    aliases = [
        ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"),   # API key 别名
        ("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"),   # 反向别名
        ("CLAUDE_MODEL", "ANTHROPIC_MODEL"),              # 模型别名
        ("GITHUB_TOKEN", "GIT_TOKEN"),                    # Git token 别名
        ("GH_TOKEN", "GIT_TOKEN"),                        # gh CLI token 别名
    ]
    for target, source in aliases:
        if target not in seen:
            val = os.environ.get(target) or os.environ.get(source)
            if val:
                env_entries.append({"name": target, "value": val})
                seen.add(target)

    job_deadline = k8s_cfg.get("job_deadline_seconds", 0)

    job_spec: dict = {
        "backoffLimit": 0,
        "ttlSecondsAfterFinished": 3600,
    }
    if job_deadline > 0:
        job_spec["activeDeadlineSeconds"] = job_deadline

    manifest = {
        "apiVersion": "batch/v1",
        "kind": "CronJob",
        "metadata": {
            "name": cj_name,
            "namespace": k8s_cfg.get("namespace", "claude-pipeline"),
            "labels": {
                "app.kubernetes.io/name": "claude-pipeline",
                "app.kubernetes.io/component": "agent",
                "claude-pipeline/repo": cj_slug,
            },
        },
        "spec": {
            "schedule": k8s_cfg.get("schedule", "*/10 * * * *"),
            "concurrencyPolicy": "Forbid",
            "successfulJobsHistoryLimit": 3,
            "failedJobsHistoryLimit": 3,
            "jobTemplate": {
                "spec": {
                    **job_spec,
                    "template": {
                        "metadata": {"labels": {"claude-pipeline/repo": cj_slug}},
                        "spec": {
                            "serviceAccountName": "claude-pipeline-agent",
                            "restartPolicy": "Never",
                            "volumes": [
                                {
                                    "name": "cargo-registry-cache",
                                    "persistentVolumeClaim": {"claimName": "cargo-registry-cache"},
                                }
                            ],
                            "containers": [
                                {
                                    "name": "agent",
                                    "image": docker_cfg.get("image", "claude-pipeline-agent:latest"),
                                    "imagePullPolicy": k8s_cfg.get("image_pull_policy", "Never"),
                                    "resources": {
                                        "requests": {"memory": "2Gi", "cpu": "1000m"},
                                        "limits": {"memory": "8Gi", "cpu": "4000m"},
                                    },
                                    "volumeMounts": [
                                        {
                                            "name": "cargo-registry-cache",
                                            "mountPath": "/home/pipeline/.cargo/registry",
                                        },
                                        {
                                            "name": "cargo-registry-cache",
                                            "mountPath": "/home/pipeline/.build-cache",
                                            "subPath": "_build-cache",
                                        },
                                    ],
                                    "env": env_entries,
                                }
                            ],
                        },
                    },
                }
            },
        },
    }
    return yaml.dump(manifest, default_flow_style=False, allow_unicode=True, sort_keys=False)


def ensure_namespace(namespace: str) -> None:
    """确保 namespace 和 ServiceAccount 存在。"""
    for manifest in ["namespace.yaml", "rbac.yaml"]:
        path = SCRIPT_DIR / manifest
        if path.exists():
            subprocess.run(
                ["kubectl", "apply", "-f", str(path)],
                capture_output=True,
            )


def main(argv: list[str]) -> None:
    # 解析 --inline-env 和 --name 标志
    inline_env = False
    name_override = None
    remaining: list[str] = []
    i = 0
    while i < len(argv):
        if argv[i] == "--inline-env":
            inline_env = True
            i += 1
        elif argv[i] == "--name" and i + 1 < len(argv):
            name_override = argv[i + 1]
            i += 2
        else:
            remaining.append(argv[i])
            i += 1
    argv = remaining

    cfg = load_config()
    namespace = cfg.get("kubernetes", {}).get("namespace", "claude-pipeline")

    # ── inline-env 模式：env 直接注入，跳过 Secret 检查 ──────────────
    if inline_env:
        repo_url = os.environ.get("GIT_REPO_URL") or (argv[0] if argv else "")
        if not repo_url:
            print("❌ 需要提供 repo URL（命令行参数或 env 文件中的 GIT_REPO_URL）")
            sys.exit(1)
        ensure_namespace(namespace)
        rendered = render_inline(repo_url, cfg, name_override)
        cj_slug = name_override or slug(repo_url)
        ok = apply_manifest(rendered, cj_slug)
        if ok:
            print(f"\n✅ CronJob 'claude-pipeline-{cj_slug}' 部署成功")
            print(f"\n查看状态: ./k8s-run.sh --status")
            print(f"查看日志: ./k8s-run.sh --logs")
        else:
            sys.exit(1)
        return

    # ── 标准模式：使用 Secret ─────────────────────────────────────────

    # 确定目标 repo 列表
    if argv:
        repos = [{"url": argv[0]}]
    else:
        repos = load_repos()
        if not repos:
            print("⚠️  repos.yaml 中没有 enabled 的 repo")
            return

    # 检查 Secret 是否存在
    if not check_secret_exists(namespace):
        print(f"""
❌ Secret 'claude-pipeline-secrets' 在 namespace '{namespace}' 中不存在。

请先创建 Secret:
  cp k8s/secret.yaml.example k8s/secret.yaml
  # 编辑 k8s/secret.yaml，填入 base64 编码的真实值
  kubectl apply -f k8s/secret.yaml

获取 base64 值:
  echo -n 'sk-ant-...' | base64
  echo -n 'ghp_...' | base64

或使用 --env 文件跳过 Secret（env 直接注入 pod）:
  ./k8s-run.sh --env .env.myconfig --name my-cronjob [repo_url]
""")
        sys.exit(1)

    # 确保基础资源存在
    ensure_namespace(namespace)

    print(f"\n部署 CronJob 到 namespace: {namespace}")
    print(f"目标 repo 数量: {len(repos)}\n")

    all_ok = True
    for repo in repos:
        url = repo.get("url", repo) if isinstance(repo, dict) else repo
        rendered = render_template(url, cfg)
        ok = apply_manifest(rendered, name_override or slug(url))
        if not ok:
            all_ok = False

    if all_ok:
        print(f"\n✅ 全部部署成功")
        print(f"\n查看状态: ./k8s-run.sh --status")
        print(f"查看日志: ./k8s-run.sh --logs")
    else:
        print(f"\n❌ 部分部署失败")
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
