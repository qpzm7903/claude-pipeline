"""
task_scanner.py - 任务扫描器

支持两种任务源:
  模式 A: GitHub Issues（带 claude-task 标签）
  模式 B: plan.md + SPEC/*.md 文件

plan.md 格式示例:
  ## Tasks
  - [ ] id:001 实现用户认证 API
    spec: ./specs/auth.md
    priority: high
  - [x] id:002 添加单元测试（已完成）
  - [-] id:003 进行中的任务

任务状态标记:
  [ ] = 待处理 (pending)
  [x] = 已完成
  [-] = 进行中
"""

import hashlib
import logging
import re
import tempfile
from pathlib import Path
from typing import Optional
import subprocess

import yaml

from .task_queue import Task, TaskQueue, TaskStatus

logger = logging.getLogger(__name__)

# plan.md 中任务行的正则: 匹配 "- [ ] id:001 任务标题"
TASK_LINE_RE = re.compile(
    r"^-\s+\[(?P<done>[x\-\s])\]\s+(?:id:(?P<id>\w+)\s+)?(?P<title>.+)$"
)
# 任务下方的元数据行: "  spec: ./specs/xxx.md"
META_LINE_RE = re.compile(r"^\s{2,}(?P<key>\w+):\s*(?P<value>.+)$")


class TaskScanner:
    def __init__(self, repo_config: dict, queue: TaskQueue, git_token: str = ""):
        self.repo = repo_config
        self.queue = queue
        self.git_token = git_token
        self.repo_name = repo_config["name"]
        self.repo_url = repo_config["url"]
        self.task_source = repo_config.get("task_source", "plan_md")

    def scan(self) -> int:
        """扫描任务源，将新任务写入队列。返回新增任务数。"""
        if self.task_source == "plan_md":
            return self._scan_plan_md()
        elif self.task_source == "github_issues":
            return self._scan_github_issues()
        else:
            logger.warning(f"Unknown task_source: {self.task_source}")
            return 0

    # ------------------------------------------------------------------ #
    # 模式 B: plan.md 扫描
    # ------------------------------------------------------------------ #

    def _scan_plan_md(self) -> int:
        """克隆/拉取仓库，解析 plan.md，提取 pending 任务。"""
        plan_file = self.repo.get("plan_file", "plan.md")
        spec_dir = self.repo.get("spec_dir", "specs")

        with tempfile.TemporaryDirectory(prefix="claude-scan-") as tmpdir:
            try:
                self._shallow_clone(tmpdir)
            except RuntimeError as e:
                logger.error(f"[{self.repo_name}] Clone failed: {e}")
                return 0

            plan_path = Path(tmpdir) / plan_file
            if not plan_path.exists():
                logger.warning(f"[{self.repo_name}] {plan_file} not found, skipping")
                return 0

            tasks = self._parse_plan_md(plan_path, Path(tmpdir) / spec_dir)

        added = 0
        for task in tasks:
            if self.queue.upsert(task):
                added += 1
        logger.info(f"[{self.repo_name}] Scan complete: {added} new tasks enqueued")
        return added

    def _shallow_clone(self, target_dir: str):
        """浅克隆仓库（只需读取 plan.md，不需完整历史）。"""
        url = self._authenticated_url()
        result = subprocess.run(
            ["git", "clone", "--depth=1", url, target_dir],
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip())

    def _authenticated_url(self) -> str:
        """在 URL 中注入 token（HTTPS + token 方式，无需 SSH key）。"""
        if not self.git_token:
            return self.repo_url
        url = self.repo_url
        if url.startswith("https://"):
            url = url.replace("https://", f"https://x-access-token:{self.git_token}@")
        return url

    def _parse_plan_md(self, plan_path: Path, spec_dir: Path) -> list[Task]:
        """
        解析 plan.md，返回所有 pending ([ ]) 任务列表。

        任务 ID 策略（两种格式都支持）:
          - 显式 ID: "- [ ] id:001 标题" → task_id = "{repo_name}_001"
          - 隐式 ID: "- [ ] 标题" → task_id = "{repo_name}_{sha1(title)[:8]}"
        """
        content = plan_path.read_text(encoding="utf-8")
        lines = content.splitlines()
        tasks: list[Task] = []

        i = 0
        while i < len(lines):
            line = lines[i]
            m = TASK_LINE_RE.match(line)
            if not m:
                i += 1
                continue

            done_marker = m.group("done").strip()
            # 只处理 [ ]（空格）= pending 任务
            if done_marker in ("x", "-"):
                i += 1
                continue

            raw_id = m.group("id")
            title = m.group("title").strip()

            # 生成稳定的任务 ID
            if raw_id:
                task_id = f"{self.repo_name}_{raw_id}"
            else:
                title_hash = hashlib.sha1(title.encode()).hexdigest()[:8]
                task_id = f"{self.repo_name}_{title_hash}"

            # 解析紧跟任务行的元数据（缩进 ≥2 的行）
            meta: dict[str, str] = {}
            i += 1
            while i < len(lines):
                meta_m = META_LINE_RE.match(lines[i])
                if meta_m:
                    meta[meta_m.group("key")] = meta_m.group("value").strip()
                    i += 1
                else:
                    break  # 遇到非元数据行则停止

            # 读取 SPEC 文件内容
            spec_content = ""
            spec_rel = meta.get("spec", "")
            if spec_rel:
                spec_path = plan_path.parent / spec_rel.lstrip("./")
                if spec_path.exists():
                    spec_content = spec_path.read_text(encoding="utf-8")
                else:
                    logger.warning(f"Spec file not found: {spec_path}")

            tasks.append(
                Task(
                    task_id=task_id,
                    title=title,
                    description=title,  # plan.md 没有正文，用标题作描述
                    repo_name=self.repo_name,
                    repo_url=self.repo_url,
                    branch=f"task/{task_id}",
                    spec_content=spec_content,
                    test_command=self.repo.get("test_command", "pytest"),
                    language=self.repo.get("language", "python"),
                    status=TaskStatus.PENDING,
                )
            )

        return tasks

    # ------------------------------------------------------------------ #
    # 模式 A: GitHub Issues 扫描
    # ------------------------------------------------------------------ #

    def _scan_github_issues(self) -> int:
        """通过 GitHub REST API 获取带指定标签的 open Issues。"""
        try:
            import urllib.request
            import urllib.error
        except ImportError:
            logger.error("urllib not available")
            return 0

        labels = ",".join(self.repo.get("labels", ["claude-task"]))
        # 从仓库 URL 中提取 owner/repo
        owner_repo = self._extract_owner_repo()
        if not owner_repo:
            logger.error(f"Cannot extract owner/repo from: {self.repo_url}")
            return 0

        api_url = (
            f"https://api.github.com/repos/{owner_repo}/issues"
            f"?state=open&labels={labels}&per_page=50"
        )
        headers = {
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "claude-pipeline/1.0",
        }
        if self.git_token:
            headers["Authorization"] = f"token {self.git_token}"

        try:
            req = urllib.request.Request(api_url, headers=headers)
            with urllib.request.urlopen(req, timeout=30) as resp:
                import json
                issues = json.loads(resp.read().decode())
        except Exception as e:
            logger.error(f"[{self.repo_name}] GitHub API error: {e}")
            return 0

        added = 0
        for issue in issues:
            if issue.get("pull_request"):
                continue  # 跳过 PR

            task_id = f"{self.repo_name}_issue{issue['number']}"
            body = issue.get("body") or ""
            task = Task(
                task_id=task_id,
                title=issue["title"],
                description=body,
                repo_name=self.repo_name,
                repo_url=self.repo_url,
                branch=f"task/{task_id}",
                spec_content=body,  # Issue body 即为 spec
                test_command=self.repo.get("test_command", "pytest"),
                language=self.repo.get("language", "python"),
                status=TaskStatus.PENDING,
            )
            if self.queue.upsert(task):
                added += 1

        logger.info(f"[{self.repo_name}] GitHub Issues scan: {added} new tasks")
        return added

    def _extract_owner_repo(self) -> Optional[str]:
        """从 GitHub URL 中提取 'owner/repo' 部分。"""
        url = self.repo_url.rstrip("/")
        if url.endswith(".git"):
            url = url[:-4]
        parts = url.split("github.com/")
        if len(parts) == 2:
            return parts[1]
        return None
