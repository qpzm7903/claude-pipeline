"""
container_manager.py - Docker 容器生命周期管理

每个任务在独立容器中运行:
  - 资源隔离（内存/CPU 限制）
  - 自动清理（auto_remove=True）
  - 1小时硬超时
  - 日志收集到本地文件
"""

import logging
import os
from pathlib import Path
from typing import Optional

import docker
from docker.errors import DockerException, ImageNotFound

from .task_queue import Task, TaskQueue, TaskStatus

logger = logging.getLogger(__name__)


class ContainerManager:
    def __init__(self, config: dict, queue: TaskQueue, log_dir: str = "./logs"):
        self.config = config
        self.queue = queue
        self.log_dir = Path(log_dir)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self._docker: Optional[docker.DockerClient] = None

    @property
    def docker(self) -> docker.DockerClient:
        if self._docker is None:
            self._docker = docker.from_env()
        return self._docker

    def _ensure_image(self, image: str) -> bool:
        """检查镜像是否存在，不存在时尝试构建。"""
        try:
            self.docker.images.get(image)
            return True
        except ImageNotFound:
            logger.warning(f"Image {image} not found, attempting to build...")
            agent_dir = Path(__file__).parent.parent / "agent"
            if not (agent_dir / "Dockerfile").exists():
                logger.error("agent/Dockerfile not found")
                return False
            try:
                self.docker.images.build(
                    path=str(agent_dir),
                    tag=image,
                    rm=True,
                )
                logger.info(f"Image {image} built successfully")
                return True
            except DockerException as e:
                logger.error(f"Image build failed: {e}")
                return False

    def run_task(self, task: Task) -> bool:
        """
        在独立 Docker 容器中运行任务。
        返回 True 表示任务完成（不一定成功），False 表示启动失败。
        """
        docker_cfg = self.config.get("docker", {})
        agent_cfg = self.config.get("agent", {})
        image = docker_cfg.get("image", "claude-pipeline-agent:latest")

        if not self._ensure_image(image):
            self.queue.update_status(
                task.task_id,
                TaskStatus.FAILED,
                error_message="Docker image not available",
            )
            return False

        env = self._build_env(task, agent_cfg)
        log_file = self.log_dir / f"{task.task_id}.log"
        timeout = self.config.get("pipeline", {}).get("container_timeout_seconds", 3600)

        logger.info(f"Starting container for task: {task.task_id}")
        try:
            container = self.docker.containers.run(
                image=image,
                environment=env,
                remove=False,           # 先保留以便收集日志
                detach=True,
                mem_limit=docker_cfg.get("mem_limit", "4g"),
                cpu_quota=docker_cfg.get("cpu_quota", 100000),
                network_mode=docker_cfg.get("network_mode", "bridge"),
                labels={
                    "claude-pipeline": "true",
                    "task-id": task.task_id,
                },
            )
            self.queue.update_status(
                task.task_id,
                TaskStatus.RUNNING,
                container_id=container.short_id,
            )
            logger.info(f"Container {container.short_id} started for task {task.task_id}")

            # 等待容器完成（带超时）
            result = container.wait(timeout=timeout)
            exit_code = result.get("StatusCode", -1)

            # 收集日志
            logs = container.logs(stdout=True, stderr=True).decode("utf-8", errors="replace")
            log_file.write_text(logs, encoding="utf-8")
            logger.info(f"Task {task.task_id} logs saved to {log_file}")

            # 手动删除容器
            try:
                container.remove(force=True)
            except DockerException:
                pass

            if exit_code == 0:
                self.queue.update_status(task.task_id, TaskStatus.COMPLETED)
                logger.info(f"Task {task.task_id} completed successfully")
                return True
            else:
                # 从日志末尾提取错误摘要（最后200个字符）
                error_summary = logs[-200:].strip() if logs else f"exit code {exit_code}"
                self.queue.update_status(
                    task.task_id,
                    TaskStatus.FAILED,
                    error_message=error_summary,
                )
                logger.error(f"Task {task.task_id} failed with exit code {exit_code}")
                return True  # 容器正常退出（只是任务失败）

        except Exception as e:
            logger.exception(f"Container error for task {task.task_id}: {e}")
            self.queue.update_status(
                task.task_id,
                TaskStatus.FAILED,
                error_message=str(e),
            )
            return False

    def _build_env(self, task: Task, agent_cfg: dict) -> dict:
        """构建容器环境变量。敏感信息从主机环境变量中读取，不硬编码。

        优先级（高 → 低）: 主机环境变量 > config.yaml > 内置默认值
        """
        anthropic_cfg = self.config.get("anthropic", {})

        # base_url: 环境变量优先，其次 config，最终留空（claude CLI 使用官方默认）
        # Anthropic SDK 自动追加 /v1，若 base_url 末尾已有 /v1 则去掉，避免 /v1/v1 重复
        base_url = (
            os.environ.get("ANTHROPIC_BASE_URL")
            or anthropic_cfg.get("base_url", "")
        )
        # model: 兼容 ANTHROPIC_MODEL / CLAUDE_MODEL 两种命名，其次 config
        model = (
            os.environ.get("ANTHROPIC_MODEL")
            or os.environ.get("CLAUDE_MODEL")
            or anthropic_cfg.get("model", "claude-opus-4-5-20251001")
        )
        # api_key: 兼容 ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY 两种命名
        api_key = (
            os.environ.get("ANTHROPIC_API_KEY")
            or os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
        )

        env = {
            "TASK_JSON": task.to_json(),
            "TASK_ID": task.task_id,
            "TASK_TITLE": task.title,
            "REPO_URL": task.repo_url,
            "REPO_NAME": task.repo_name,
            "BRANCH_NAME": task.branch,
            "TEST_COMMAND": task.test_command,
            "LANGUAGE": task.language,
            # Anthropic 认证（claude CLI 固定读取 ANTHROPIC_API_KEY）
            "ANTHROPIC_API_KEY": api_key,
            "GIT_TOKEN": os.environ.get("GIT_TOKEN", ""),
            "GITHUB_TOKEN": os.environ.get("GITHUB_TOKEN", ""),
            # Anthropic 连接配置
            "CLAUDE_MODEL": model,
            # Agent 配置
            "TDD_TIMEOUT": str(agent_cfg.get("tdd_timeout", 600)),
            "CODING_TIMEOUT": str(agent_cfg.get("coding_timeout", 600)),
            "REVIEW_TIMEOUT": str(agent_cfg.get("review_timeout", 300)),
            "MAX_CODING_RETRIES": str(agent_cfg.get("max_coding_retries", 3)),
            "GIT_AUTHOR_NAME": self.config.get("git", {}).get("author_name", "Claude Pipeline Bot"),
            "GIT_AUTHOR_EMAIL": self.config.get("git", {}).get("author_email", "pipeline@claude.ai"),
        }
        # 只在非空时注入 ANTHROPIC_BASE_URL，避免覆盖 claude CLI 的内置默认
        if base_url:
            env["ANTHROPIC_BASE_URL"] = base_url
        return env

    def count_running_containers(self) -> int:
        """统计当前属于 claude-pipeline 的运行中容器数量。"""
        try:
            containers = self.docker.containers.list(
                filters={"label": "claude-pipeline=true", "status": "running"}
            )
            return len(containers)
        except DockerException as e:
            logger.warning(f"Cannot count containers: {e}")
            return 0

    def cleanup_stopped_containers(self):
        """清理已停止但未删除的 pipeline 容器（容错）。"""
        try:
            containers = self.docker.containers.list(
                all=True,
                filters={"label": "claude-pipeline=true", "status": "exited"},
            )
            for c in containers:
                c.remove()
                logger.debug(f"Cleaned up container: {c.short_id}")
        except DockerException as e:
            logger.warning(f"Cleanup error: {e}")
