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
        "{JOB_DEADLINE}": str(k8s_cfg.get("job_deadline_seconds", 7200)),
    }

    result = template
    for placeholder, value in replacements.items():
        result = result.replace(placeholder, value)
    return result


def apply_manifest(content: str, repo_url: str) -> bool:
    """写临时文件并 kubectl apply。"""
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
            print(f"  ✅ {slug(repo_url)}: {result.stdout.strip()}")
            return True
        else:
            print(f"  ❌ {slug(repo_url)}: {result.stderr.strip()}")
            return False
    finally:
        os.unlink(tmp_path)


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
    cfg = load_config()
    namespace = cfg.get("kubernetes", {}).get("namespace", "claude-pipeline")

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
        ok = apply_manifest(rendered, url)
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
