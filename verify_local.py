"""
verify_local.py - 本地验证脚本（不需要 Docker）

用法:
  python verify_local.py                      # 完整验证
  python verify_local.py --test-scanner       # 只测试 plan.md 解析
  python verify_local.py --test-prompt tdd    # 测试指定 phase 的 prompt 生成
"""

import argparse
import json
import os
import sys
import tempfile
import shutil
from pathlib import Path

# 确保项目根目录在 path 中
sys.path.insert(0, str(Path(__file__).parent))


def test_plan_md_parsing():
    """测试 plan.md 解析逻辑（使用 example_repo 目录）。"""
    print("\n" + "="*50)
    print("测试 1: plan.md 解析")
    print("="*50)

    from orchestrator.task_queue import TaskQueue, TaskStatus
    from orchestrator.task_scanner import TaskScanner

    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        db_path = f.name

    try:
        queue = TaskQueue(db_path)

        # 模拟 repo 配置（使用本地 example_repo 目录）
        example_dir = Path(__file__).parent / "example_repo"
        repo_config = {
            "name": "test-repo",
            "url": "https://github.com/example/test-repo",
            "task_source": "plan_md",
            "plan_file": "plan.md",
            "spec_dir": "specs",
            "test_command": "pytest",
            "language": "python",
        }

        scanner = TaskScanner(repo_config, queue)

        # 直接解析本地 plan.md（不克隆远端仓库）
        plan_path = example_dir / "plan.md"
        spec_dir = example_dir / "specs"
        tasks = scanner._parse_plan_md(plan_path, spec_dir)

        print(f"\n解析到 {len(tasks)} 个 pending 任务:")
        for t in tasks:
            print(f"  - ID: {t.task_id}")
            print(f"    Title: {t.title}")
            print(f"    Spec length: {len(t.spec_content)} chars")
            spec_preview = t.spec_content[:100].replace('\n', ' ') if t.spec_content else "(empty)"
            print(f"    Spec preview: {spec_preview}...")
            print()

        assert len(tasks) == 2, f"Expected 2 tasks, got {len(tasks)}"
        assert tasks[0].task_id == "test-repo_001"
        assert tasks[1].task_id == "test-repo_002"
        assert len(tasks[0].spec_content) > 0, "Spec content should be loaded"
        print("✅ plan.md 解析测试通过！")
        return True

    except Exception as e:
        print(f"❌ 测试失败: {e}")
        import traceback; traceback.print_exc()
        return False
    finally:
        os.unlink(db_path)


def test_task_queue():
    """测试任务队列的状态机操作。"""
    print("\n" + "="*50)
    print("测试 2: 任务队列状态机")
    print("="*50)

    from orchestrator.task_queue import TaskQueue, Task, TaskStatus

    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        db_path = f.name

    try:
        queue = TaskQueue(db_path)

        # 测试插入
        task = Task(
            task_id="test_001",
            title="测试任务",
            description="这是一个测试",
            repo_name="test-repo",
            repo_url="https://github.com/example/test",
            branch="task/test_001",
        )
        inserted = queue.upsert(task)
        assert inserted, "First insert should succeed"

        # 测试幂等性
        inserted_again = queue.upsert(task)
        assert not inserted_again, "Duplicate insert should return False"

        # 测试 claim_pending（原子性）
        claimed = queue.claim_pending()
        assert claimed is not None
        assert claimed.task_id == "test_001"
        assert claimed.status == TaskStatus.RUNNING
        print(f"  Claimed task: {claimed.task_id} → {claimed.status.value}")

        # 第二次 claim 应返回 None（没有其他 pending 任务）
        claimed2 = queue.claim_pending()
        assert claimed2 is None, "No more pending tasks"

        # 测试状态更新
        queue.update_status("test_001", TaskStatus.COMPLETED, pr_url="https://github.com/pr/1")
        task_updated = queue.get_task("test_001")
        assert task_updated.status == TaskStatus.COMPLETED
        assert task_updated.pr_url == "https://github.com/pr/1"
        print(f"  Updated to: {task_updated.status.value}")

        # 测试并发计数
        count = queue.count_running()
        assert count == 0, f"Expected 0 running, got {count}"
        print(f"  Running count: {count}")

        print("✅ 任务队列测试通过！")
        return True

    except Exception as e:
        print(f"❌ 测试失败: {e}")
        import traceback; traceback.print_exc()
        return False
    finally:
        os.unlink(db_path)


def test_prompt_generation(phase: str = "tdd"):
    """测试指定 phase 的 prompt 生成。"""
    print("\n" + "="*50)
    print(f"测试 3: Prompt 生成 ({phase})")
    print("="*50)

    # 在 PATH 中找到 agent 目录
    agent_dir = Path(__file__).parent / "agent"
    sys.path.insert(0, str(agent_dir))

    import task_runner

    task = {
        "task_id": "test-repo_001",
        "title": "实现 Calculator 类",
        "description": "实现一个支持基本四则运算的 Calculator 类",
        "language": "python",
        "test_command": "pytest",
        "spec_content": Path(__file__).parent / "example_repo" / "specs" / "calculator.md",
    }
    # 读取 spec 内容
    spec_path = Path(task["spec_content"])
    task["spec_content"] = spec_path.read_text() if spec_path.exists() else ""

    workspace = str(Path(__file__).parent / "example_repo")

    if phase == "tdd":
        prompt = task_runner.build_tdd_prompt(task, workspace)
    elif phase == "coding":
        prompt = task_runner.build_coding_prompt(task, workspace, retry=0)
    elif phase == "review":
        prompt = task_runner.build_review_prompt(task, workspace)
    else:
        print(f"Unknown phase: {phase}")
        return False

    print(f"\n生成的 {phase.upper()} Prompt（{len(prompt)} chars）:")
    print("-" * 40)
    print(prompt[:1500])
    if len(prompt) > 1500:
        print(f"\n... (truncated, total {len(prompt)} chars)")
    print("-" * 40)
    print(f"✅ {phase} prompt 生成成功！")
    return True


def main():
    parser = argparse.ArgumentParser(description="Claude Pipeline 本地验证")
    parser.add_argument("--test-scanner", action="store_true", help="只测试 plan.md 解析")
    parser.add_argument("--test-queue", action="store_true", help="只测试任务队列")
    parser.add_argument("--test-prompt", choices=["tdd", "coding", "review"], help="测试 prompt 生成")
    args = parser.parse_args()

    results = []

    if args.test_scanner:
        results.append(test_plan_md_parsing())
    elif args.test_queue:
        results.append(test_task_queue())
    elif args.test_prompt:
        results.append(test_prompt_generation(args.test_prompt))
    else:
        # 运行所有测试
        results.append(test_plan_md_parsing())
        results.append(test_task_queue())
        results.append(test_prompt_generation("tdd"))

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
