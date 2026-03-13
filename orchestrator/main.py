"""
main.py - Claude Pipeline 主调度循环

运行方式:
  python -m orchestrator.main                   # 正常运行
  python -m orchestrator.main --dry-run         # 仅扫描，不启动容器
  python -m orchestrator.main --once            # 执行一次后退出
  python -m orchestrator.main --status          # 查看任务状态后退出
"""

import argparse
import logging
import os
import signal
import sys
import time
from pathlib import Path

import yaml

# 确保项目根目录在 Python 路径中
sys.path.insert(0, str(Path(__file__).parent.parent))

from orchestrator.task_scanner import TaskScanner
from orchestrator.task_queue import TaskQueue, TaskStatus
from orchestrator.container_manager import ContainerManager

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("pipeline.main")

# 用于优雅退出的标志
_running = True


def _handle_signal(signum, frame):
    global _running
    logger.info(f"Received signal {signum}, shutting down gracefully...")
    _running = False


def load_config(config_dir: str = "./config") -> tuple[dict, list[dict]]:
    config_path = Path(config_dir) / "config.yaml"
    repos_path = Path(config_dir) / "repos.yaml"

    with open(config_path, "r", encoding="utf-8") as f:
        config = yaml.safe_load(f)
    with open(repos_path, "r", encoding="utf-8") as f:
        repos_data = yaml.safe_load(f)

    repos = [r for r in repos_data.get("repos", []) if r.get("enabled", True)]
    return config, repos


def print_status(queue: TaskQueue):
    tasks = queue.list_tasks()
    if not tasks:
        print("No tasks found.")
        return

    print(f"\n{'ID':<30} {'STATUS':<12} {'TITLE':<40} {'CREATED':<25}")
    print("-" * 110)
    for t in tasks:
        created = t.created_at[:19].replace("T", " ") if t.created_at else "-"
        title = t.title[:38] + ".." if len(t.title) > 40 else t.title
        print(f"{t.task_id:<30} {t.status.value:<12} {title:<40} {created:<25}")

    status_counts = {}
    for t in tasks:
        status_counts[t.status.value] = status_counts.get(t.status.value, 0) + 1
    print(f"\nTotal: {len(tasks)} | " + " | ".join(f"{k}: {v}" for k, v in status_counts.items()))


def run_scan_cycle(repos: list[dict], queue: TaskQueue, git_token: str, dry_run: bool) -> int:
    """执行一轮扫描，返回新增任务数。"""
    total_new = 0
    for repo in repos:
        scanner = TaskScanner(repo, queue, git_token)
        try:
            new_count = scanner.scan()
            total_new += new_count
        except Exception as e:
            logger.error(f"Scan error for {repo['name']}: {e}")
    return total_new


def run_dispatch_cycle(
    queue: TaskQueue,
    manager: ContainerManager,
    max_concurrent: int,
    dry_run: bool,
):
    """将 pending 任务分发到容器（直到达到并发上限）。"""
    running_count = queue.count_running()
    slots = max_concurrent - running_count

    if slots <= 0:
        logger.debug(f"No slots available ({running_count}/{max_concurrent} running)")
        return

    dispatched = 0
    while dispatched < slots:
        task = queue.claim_pending()
        if task is None:
            break

        if dry_run:
            logger.info(f"[DRY RUN] Would dispatch task: {task.task_id} - {task.title}")
            # dry-run 模式下将任务重置为 pending
            queue.update_status(task.task_id, TaskStatus.PENDING)
        else:
            logger.info(f"Dispatching task: {task.task_id} - {task.title}")
            # 在新线程中运行容器，避免阻塞主循环
            import threading
            t = threading.Thread(
                target=manager.run_task,
                args=(task,),
                daemon=True,
                name=f"task-{task.task_id}",
            )
            t.start()

        dispatched += 1


def main():
    parser = argparse.ArgumentParser(description="Claude Pipeline Orchestrator")
    parser.add_argument("--dry-run", action="store_true", help="只扫描，不启动容器")
    parser.add_argument("--once", action="store_true", help="执行一次后退出")
    parser.add_argument("--status", action="store_true", help="查看任务状态后退出")
    parser.add_argument("--config-dir", default="./config", help="配置文件目录")
    parser.add_argument("--db", default="./pipeline.db", help="SQLite 数据库路径")
    args = parser.parse_args()

    # 加载配置
    try:
        config, repos = load_config(args.config_dir)
    except FileNotFoundError as e:
        logger.error(f"Config file not found: {e}")
        sys.exit(1)

    queue = TaskQueue(args.db)

    # --status: 打印状态后退出
    if args.status:
        print_status(queue)
        return

    pipeline_cfg = config.get("pipeline", {})
    poll_interval = pipeline_cfg.get("poll_interval_seconds", 300)
    max_concurrent = pipeline_cfg.get("max_concurrent_containers", 3)
    log_dir = pipeline_cfg.get("log_dir", "./logs")
    git_token = os.environ.get("GIT_TOKEN") or os.environ.get("GITHUB_TOKEN", "")

    manager = ContainerManager(config, queue, log_dir=log_dir)

    # 注册信号处理器实现优雅退出
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    mode_label = "[DRY RUN] " if args.dry_run else ""
    logger.info(f"{mode_label}Claude Pipeline started")
    logger.info(f"Monitoring {len(repos)} repo(s), poll interval: {poll_interval}s, max concurrent: {max_concurrent}")

    global _running
    while _running:
        try:
            # 1. 扫描新任务
            new_tasks = run_scan_cycle(repos, queue, git_token, args.dry_run)
            if new_tasks:
                logger.info(f"Found {new_tasks} new task(s)")

            # 2. 分发任务到容器
            run_dispatch_cycle(queue, manager, max_concurrent, args.dry_run)

            # 3. 清理残留容器
            if not args.dry_run:
                manager.cleanup_stopped_containers()

        except Exception as e:
            logger.exception(f"Cycle error: {e}")

        if args.once:
            logger.info("--once flag set, exiting after one cycle")
            break

        # 等待下一轮（每秒检查一次退出信号）
        for _ in range(poll_interval):
            if not _running:
                break
            time.sleep(1)

    logger.info("Claude Pipeline stopped")


if __name__ == "__main__":
    main()
