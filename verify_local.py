"""
verify_local.py — 本地结构验证（不需要 Docker / K8s）

校验项：
  - 三大中心目录布局完整
  - centers.yaml 关键字段
  - assemble.sh 与 components/run.sh 关键逻辑
  - 现有 tasks/<name>/ 自包含

用法:
  python3 verify_local.py            # 全部
  python3 verify_local.py --centers  # 仅 centers.yaml
  python3 verify_local.py --assemble # 仅 assemble.sh + run.sh
  python3 verify_local.py --tasks    # 仅 tasks/
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).parent


def _check(label, ok):
    print(f"  {'✅' if ok else '❌'} {label}")
    return ok


def test_layout():
    print("\n=== 三大中心目录布局 ===")
    expected = [
        "agent/Dockerfile.general-base",
        "agent/Dockerfile.general-agent",
        "agent/lib/fmt_stream.py",
        "k8s/litellm.yaml",
        "k8s/setup-litellm.sh",
        "job-agent/assemble.sh",
        "job-agent/components/run.sh",
        "job-agent/components/settings.json",
        "config/centers.yaml",
    ]
    return all(_check(p, (ROOT / p).exists()) for p in expected)


def test_centers():
    print("\n=== config/centers.yaml ===")
    path = ROOT / "config" / "centers.yaml"
    if not _check("centers.yaml 存在", path.exists()):
        return False
    try:
        import yaml
    except ImportError:
        print("  ⚠️  PyYAML 未安装，跳过解析校验")
        return True
    cfg = yaml.safe_load(path.read_text()) or {}
    ok = True
    for section in ("image", "litellm", "kubernetes"):
        ok &= _check(f"{section}: 段存在", section in cfg)
    if "image" in cfg:
        for stack in ("general", "java", "rust"):
            ok &= _check(
                f"image.{stack} 已定义",
                stack in cfg["image"],
            )
    if "litellm" in cfg:
        for key in ("base_url", "secret_name", "secret_key"):
            ok &= _check(
                f"litellm.{key} 已定义",
                key in cfg["litellm"],
            )
    return ok


def test_assemble():
    print("\n=== job-agent/assemble.sh + components/run.sh ===")
    assemble = (ROOT / "job-agent" / "assemble.sh").read_text()
    run_sh = (ROOT / "job-agent" / "components" / "run.sh").read_text()
    ok = True
    for kw in ("# assemble:", "ConfigMap", "Job", "skills", "settings.json"):
        ok &= _check(f"assemble.sh 包含 {kw!r}", kw in assemble)
    for kw in ("REPO_URL", "ANTHROPIC_API_KEY", "git clone", "claude", "stream-json"):
        ok &= _check(f"components/run.sh 包含 {kw!r}", kw in run_sh)
    return ok


def test_tasks():
    print("\n=== tasks/<name>/ 自包含校验 ===")
    tasks_dir = ROOT / "job-agent" / "tasks"
    if not tasks_dir.exists():
        return _check("tasks/ 存在", False)
    ok = True
    for sub in sorted(p for p in tasks_dir.iterdir() if p.is_dir()):
        job_yml = sub / "job.yml"
        prompt_md = sub / "prompt.md"
        ok &= _check(f"{sub.name}/job.yml", job_yml.exists())
        ok &= _check(f"{sub.name}/prompt.md", prompt_md.exists())
        if job_yml.exists():
            head = job_yml.read_text(errors="ignore")[:2000]
            ok &= _check(
                f"{sub.name}/job.yml 含 # assemble: 元数据",
                "# assemble:" in head,
            )
    return ok


def main():
    parser = argparse.ArgumentParser(description="Claude Pipeline 结构验证")
    parser.add_argument("--centers", action="store_true")
    parser.add_argument("--assemble", action="store_true")
    parser.add_argument("--tasks", action="store_true")
    args = parser.parse_args()

    results = []
    if args.centers:
        results.append(test_centers())
    elif args.assemble:
        results.append(test_assemble())
    elif args.tasks:
        results.append(test_tasks())
    else:
        results.append(test_layout())
        results.append(test_centers())
        results.append(test_assemble())
        results.append(test_tasks())

    passed = sum(results)
    total = len(results)
    print()
    if passed == total:
        print(f"✅ 全部通过: {passed}/{total}")
    else:
        print(f"❌ 部分失败: {passed}/{total} 通过")
        sys.exit(1)


if __name__ == "__main__":
    main()
