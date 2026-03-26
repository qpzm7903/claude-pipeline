"""
verify_local.py - 本地验证脚本（不需要 Docker）

用法:
  python verify_local.py                    # 完整验证
  python verify_local.py --test-prompt      # 测试 entrypoint 工作流完整性
  python verify_local.py --test-config      # 验证 config.yaml 结构
"""

import argparse
import sys
from pathlib import Path


def test_entrypoint_prompt():
    """验证 agent/ 目录的整体工作流完整性（entrypoint + lib 模块 + prompt 文件）。"""
    print("\n" + "="*50)
    print("测试 1: Agent 工作流完整性")
    print("="*50)

    agent_dir = Path(__file__).parent / "agent"
    entrypoint = agent_dir / "entrypoint.sh"
    if not entrypoint.exists():
        print(f"❌ 文件不存在: {entrypoint}")
        return False

    # 收集 entrypoint.sh + lib/ 下所有源文件的内容
    agent_content = entrypoint.read_text()
    lib_dir = agent_dir / "lib"
    if lib_dir.is_dir():
        for f in lib_dir.iterdir():
            if f.suffix in (".sh", ".py"):
                agent_content += "\n" + f.read_text()
    # 包含 container-CLAUDE.md（容器内的行为规范）
    container_claude = agent_dir / "container-CLAUDE.md"
    if container_claude.exists():
        agent_content += "\n" + container_claude.read_text()
    # 包含 prompt 文件（.txt）
    for f in agent_dir.iterdir():
        if f.suffix == ".txt":
            agent_content += "\n" + f.read_text()

    # 检查 agent 源码中的关键字（entrypoint + lib 模块）
    source_checks = [
        ("步骤 0: 环境检查",         "环境检查步骤"),
        ("步骤 1: 克隆仓库",         "克隆仓库步骤"),
        ("步骤 2: Claude 自主执行",   "Claude 执行步骤"),
        ("git clone",               "克隆命令"),
        ("claude",                  "Claude CLI 调用"),
        ("stream-json",             "stream-json 输出格式"),
        ("_fmt_stream",             "格式化函数"),
        ("ANTHROPIC_API_KEY",       "API key 检查"),
        ("REPO_URL",                "仓库 URL 变量"),
        ("CLAUDE.md",               "CLAUDE.md 引用"),
    ]

    all_ok = True
    for keyword, description in source_checks:
        if keyword in agent_content:
            print(f"  ✅ {description}")
        else:
            print(f"  ❌ 缺少: {description} (关键字: {keyword!r})")
            all_ok = False

    # 检查 prompt 文件存在性与基本结构
    prompt_files = {
        "default-prompt.txt": ["BMAD", "bmad-", "单步执行"],
        "auto-iterate-prompt.txt": ["优先级", "git push", "P4"],
    }
    for fname, keywords in prompt_files.items():
        fpath = agent_dir / fname
        if not fpath.exists():
            print(f"  ❌ Prompt 文件缺失: {fname}")
            all_ok = False
            continue
        print(f"  ✅ Prompt 文件存在: {fname}")
        pcontent = fpath.read_text()
        for kw in keywords:
            if kw not in pcontent:
                print(f"    ❌ {fname} 缺少关键字: {kw!r}")
                all_ok = False

    if all_ok:
        print("✅ Agent 工作流验证通过！")
    return all_ok


def test_config():
    """验证 config.yaml 不含已删除的 pipeline/agent 段。"""
    print("\n" + "="*50)
    print("测试 2: config.yaml 结构验证")
    print("="*50)

    try:
        import yaml
    except ImportError:
        print("  ⚠️  PyYAML 未安装，跳过 yaml 解析（仍做文本检查）")
        yaml = None

    cfg_path = Path(__file__).parent / "config" / "config.yaml"
    if not cfg_path.exists():
        print(f"❌ 文件不存在: {cfg_path}")
        return False

    content = cfg_path.read_text()

    # 确认已删除的段不存在
    removed_keys = ["poll_interval_seconds", "max_concurrent_containers", "tdd_timeout"]
    for key in removed_keys:
        if key in content:
            print(f"  ❌ 已废弃的配置仍存在: {key!r}")
            return False

    # 确认必要段存在
    required_keys = ["docker:", "anthropic:", "git:"]
    for key in required_keys:
        if key in content:
            print(f"  ✅ {key}")
        else:
            print(f"  ❌ 缺少必要配置: {key!r}")
            return False

    if yaml:
        cfg = yaml.safe_load(content)
        assert "docker" in cfg, "docker 段缺失"
        assert "anthropic" in cfg, "anthropic 段缺失"
        assert "git" in cfg, "git 段缺失"
        assert "pipeline" not in cfg, "pipeline 段应已删除"
        assert "agent" not in cfg, "agent 段应已删除"

    print("✅ config.yaml 验证通过！")
    return True


def test_run_sh():
    """验证 run.sh 存在且包含必要逻辑。"""
    print("\n" + "="*50)
    print("测试 3: run.sh 完整性")
    print("="*50)

    run_sh = Path(__file__).parent / "run.sh"
    if not run_sh.exists():
        print(f"❌ 文件不存在: {run_sh}")
        return False

    content = run_sh.read_text()
    checks = [
        ("docker run",          "启动容器"),
        ("ANTHROPIC_API_KEY",   "API key 传递"),
        ("ANTHROPIC_AUTH_TOKEN","AUTH_TOKEN 兼容"),
        ("ANTHROPIC_MODEL",     "模型参数"),
        ("GIT_TOKEN",           "Git token"),
        ("ANTHROPIC_BASE_URL",  "Base URL 条件传递"),
        ("repos.yaml",          "批量模式读取 repos"),
    ]

    all_ok = True
    for keyword, description in checks:
        if keyword in content:
            print(f"  ✅ {description}")
        else:
            print(f"  ❌ 缺少: {description} (关键字: {keyword!r})")
            all_ok = False

    if all_ok:
        print("✅ run.sh 验证通过！")
    return all_ok


def test_k8s_manifests():
    """验证 K8s 相关文件存在且包含必要内容。"""
    print("\n" + "="*50)
    print("测试 4: Kubernetes 清单文件验证")
    print("="*50)

    base = Path(__file__).parent
    k8s_dir = base / "k8s"

    if not k8s_dir.exists():
        print("  ⏭️  k8s/ 目录不存在，跳过（Docker 模式不需要 K8s 文件）")
        return True

    # 检查必要文件存在
    required_files = [
        "namespace.yaml",
        "rbac.yaml",
        "cronjob-template.yaml",
        "secret.yaml.example",
        "render_and_apply.py",
    ]
    all_ok = True
    for fname in required_files:
        fpath = k8s_dir / fname
        if fpath.exists():
            print(f"  ✅ k8s/{fname}")
        else:
            print(f"  ❌ 缺少: k8s/{fname}")
            all_ok = False

    k8s_run = base / "k8s-run.sh"
    if k8s_run.exists():
        print(f"  ✅ k8s-run.sh")
    else:
        print(f"  ❌ 缺少: k8s-run.sh")
        all_ok = False

    # 检查模板占位符
    template_path = k8s_dir / "cronjob-template.yaml"
    if template_path.exists():
        template = template_path.read_text()
        placeholders = [
            "{REPO_SLUG}", "{REPO_URL}", "{SCHEDULE}", "{IMAGE}",
            "{IMAGE_PULL_POLICY}", "{MODEL}", "{ANTHROPIC_BASE_URL}",
            "{GIT_AUTHOR_NAME}", "{GIT_AUTHOR_EMAIL}",
        ]
        for ph in placeholders:
            if ph in template:
                print(f"  ✅ 模板包含占位符 {ph}")
            else:
                print(f"  ❌ 模板缺少占位符 {ph}")
                all_ok = False

        # 检查关键字段
        key_fields = [
            ("concurrencyPolicy: Forbid", "并发策略（单容器串行）"),
            ("backoffLimit: 0",          "失败不重试"),
            ("restartPolicy: Never",     "不重启"),
            ("activeDeadlineSeconds",    "超时设置"),
            ("ANTHROPIC_AUTH_TOKEN",     "AUTH_TOKEN 兼容"),
        ]
        for keyword, desc in key_fields:
            if keyword in template:
                print(f"  ✅ 模板包含 {desc} ({keyword!r})")
            else:
                print(f"  ❌ 模板缺少 {desc} ({keyword!r})")
                all_ok = False

    # 检查 config.yaml 含 kubernetes: 段
    cfg_path = base / "config" / "config.yaml"
    if cfg_path.exists() and "kubernetes:" in cfg_path.read_text():
        print("  ✅ config.yaml 包含 kubernetes: 段")
    else:
        print("  ❌ config.yaml 缺少 kubernetes: 段")
        all_ok = False

    # 安全检查：k8s/secret.yaml 不应被 git 追踪
    secret_yaml = k8s_dir / "secret.yaml"
    if secret_yaml.exists():
        import subprocess
        result = subprocess.run(
            ["git", "ls-files", "--error-unmatch", str(secret_yaml)],
            capture_output=True,
            cwd=base,
        )
        if result.returncode == 0:
            print("  ❌ 安全警告: k8s/secret.yaml 被 git 追踪！请加入 .gitignore")
            all_ok = False
        else:
            print("  ✅ k8s/secret.yaml 未被 git 追踪（安全）")
    else:
        print("  ℹ️  k8s/secret.yaml 不存在（正常，由用户自行创建）")

    if all_ok:
        print("✅ K8s 清单文件验证通过！")
    return all_ok


def test_example_claude_md():
    """验证 example_repo/CLAUDE.md 存在且包含必要内容。"""
    print("\n" + "="*50)
    print("测试 5: example_repo/CLAUDE.md 模板验证")
    print("="*50)

    example_md = Path(__file__).parent / "example_repo" / "CLAUDE.md"
    if not example_md.exists():
        print(f"❌ 文件不存在: {example_md}")
        return False

    content = example_md.read_text()
    checks = [
        ("简体中文",        "中文支持要求"),
        ("prompt.md",      "prompt.md 保护"),
        ("BMAD",           "BMAD 工作流"),
        ("代码质量",        "代码质量要求"),
        ("GitHub Actions", "CI/CD 要求"),
        ("checksums",      "校验和要求"),
        ("issue",          "issue 处理"),
    ]

    all_ok = True
    for keyword, description in checks:
        if keyword in content:
            print(f"  ✅ {description}")
        else:
            print(f"  ❌ 缺少: {description} (关键字: {keyword!r})")
            all_ok = False

    if all_ok:
        print("✅ example_repo/CLAUDE.md 验证通过！")
    return all_ok


def main():
    parser = argparse.ArgumentParser(description="Claude Pipeline 本地验证")
    parser.add_argument("--test-prompt", action="store_true", help="测试 entrypoint 工作流完整性")
    parser.add_argument("--test-config", action="store_true", help="验证 config.yaml 结构")
    parser.add_argument("--test-k8s", action="store_true", help="验证 K8s 清单文件")
    args = parser.parse_args()

    results = []

    if args.test_prompt:
        results.append(test_entrypoint_prompt())
    elif args.test_config:
        results.append(test_config())
    elif args.test_k8s:
        results.append(test_k8s_manifests())
    else:
        results.append(test_entrypoint_prompt())
        results.append(test_config())
        results.append(test_run_sh())
        results.append(test_k8s_manifests())
        results.append(test_example_claude_md())

    print("\n" + "="*50)
    passed = sum(results)
    total = len(results)
    if passed == total:
        print(f"✅ 全部通过: {passed}/{total}")
    else:
        print(f"❌ 部分失败: {passed}/{total} 通过")
        sys.exit(1)


if __name__ == "__main__":
    main()
