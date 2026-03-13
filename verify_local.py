"""
verify_local.py - 本地验证脚本（不需要 Docker）

用法:
  python verify_local.py                    # 完整验证
  python verify_local.py --test-prompt      # 测试 entrypoint 提示词片段解析
  python verify_local.py --test-config      # 验证 config.yaml 结构
"""

import argparse
import sys
from pathlib import Path


def test_entrypoint_prompt():
    """验证 entrypoint.sh 包含必要的工作流步骤。"""
    print("\n" + "="*50)
    print("测试 1: entrypoint.sh 工作流完整性")
    print("="*50)

    entrypoint = Path(__file__).parent / "agent" / "entrypoint.sh"
    if not entrypoint.exists():
        print(f"❌ 文件不存在: {entrypoint}")
        return False

    content = entrypoint.read_text()
    checks = [
        ("步骤 1.5: 任务发现与认领", "Git 原子抢占块"),
        ("git pull --rebase",    "rebase 防冲突"),
        ("grep -n",               "扫描待处理任务"),
        ("sed -i",               "标记任务为 [-]"),
        ("git push",             "push 作为分布式锁"),
        ("CLAIM_SUCCESS",        "抢占结果检查"),
        ("步骤 2: Claude 自主执行", "Claude 执行步骤"),
        ("PIPELINE_COMPLETE",   "完成标志"),
        ("IS_BMAD",              "BMAD 项目检测"),
        ("run_bmad_planning",    "BMAD 规划函数"),
        ("run_bmad_create_story", "BMAD create-story 函数"),
        ("dev-story/workflow.md", "BMAD dev-story 工作流引用"),
    ]

    all_ok = True
    for keyword, description in checks:
        if keyword in content:
            print(f"  ✅ {description}")
        else:
            print(f"  ❌ 缺少: {description} (关键字: {keyword!r})")
            all_ok = False

    if all_ok:
        print("✅ entrypoint.sh 结构验证通过！")
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


def main():
    parser = argparse.ArgumentParser(description="Claude Pipeline 本地验证")
    parser.add_argument("--test-prompt", action="store_true", help="测试 entrypoint 工作流完整性")
    parser.add_argument("--test-config", action="store_true", help="验证 config.yaml 结构")
    args = parser.parse_args()

    results = []

    if args.test_prompt:
        results.append(test_entrypoint_prompt())
    elif args.test_config:
        results.append(test_config())
    else:
        results.append(test_entrypoint_prompt())
        results.append(test_config())
        results.append(test_run_sh())

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
