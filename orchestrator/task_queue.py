"""
task_queue.py - SQLite 任务队列与状态机

状态流转:
  pending → running → testing → reviewing → completed
               ↓          ↓
            failed      failed

原子性保证: 使用 SQLite 的 BEGIN IMMEDIATE 事务防止并发重复拾取
"""

import sqlite3
import json
import logging
from datetime import datetime, timezone
from dataclasses import dataclass, asdict, field
from enum import Enum
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)


class TaskStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    TESTING = "testing"
    REVIEWING = "reviewing"
    COMPLETED = "completed"
    FAILED = "failed"


@dataclass
class Task:
    task_id: str
    title: str
    description: str
    repo_name: str
    repo_url: str
    branch: str
    spec_content: str = ""
    test_command: str = "pytest"
    language: str = "python"
    status: TaskStatus = TaskStatus.PENDING
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    started_at: Optional[str] = None
    completed_at: Optional[str] = None
    error_message: Optional[str] = None
    pr_url: Optional[str] = None
    container_id: Optional[str] = None

    def to_json(self) -> str:
        d = asdict(self)
        d["status"] = self.status.value
        return json.dumps(d, ensure_ascii=False)

    @classmethod
    def from_row(cls, row: dict) -> "Task":
        row = dict(row)
        row["status"] = TaskStatus(row["status"])
        return cls(**row)


class TaskQueue:
    def __init__(self, db_path: str = "./pipeline.db"):
        self.db_path = db_path
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")   # 支持并发读
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    def _init_db(self):
        with self._connect() as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS tasks (
                    task_id       TEXT PRIMARY KEY,
                    title         TEXT NOT NULL,
                    description   TEXT NOT NULL,
                    repo_name     TEXT NOT NULL,
                    repo_url      TEXT NOT NULL,
                    branch        TEXT NOT NULL,
                    spec_content  TEXT DEFAULT '',
                    test_command  TEXT DEFAULT 'pytest',
                    language      TEXT DEFAULT 'python',
                    status        TEXT NOT NULL DEFAULT 'pending',
                    created_at    TEXT NOT NULL,
                    started_at    TEXT,
                    completed_at  TEXT,
                    error_message TEXT,
                    pr_url        TEXT,
                    container_id  TEXT
                )
            """)
            conn.execute("CREATE INDEX IF NOT EXISTS idx_status ON tasks(status)")
            conn.commit()
        logger.info(f"TaskQueue initialized: {self.db_path}")

    def upsert(self, task: Task) -> bool:
        """插入新任务；若已存在（相同 task_id）则跳过。返回是否实际插入。"""
        with self._connect() as conn:
            existing = conn.execute(
                "SELECT task_id FROM tasks WHERE task_id = ?", (task.task_id,)
            ).fetchone()
            if existing:
                return False
            conn.execute(
                """INSERT INTO tasks
                   (task_id, title, description, repo_name, repo_url, branch,
                    spec_content, test_command, language, status, created_at)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
                (task.task_id, task.title, task.description, task.repo_name,
                 task.repo_url, task.branch, task.spec_content,
                 task.test_command, task.language, task.status.value, task.created_at),
            )
            conn.commit()
            logger.info(f"Task enqueued: {task.task_id} - {task.title}")
            return True

    def claim_pending(self) -> Optional[Task]:
        """原子性地将一个 pending 任务标记为 running 并返回。"""
        with self._connect() as conn:
            # BEGIN IMMEDIATE 保证同一时刻只有一个进程能拾取任务
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute(
                "SELECT * FROM tasks WHERE status = ? ORDER BY created_at LIMIT 1",
                (TaskStatus.PENDING.value,),
            ).fetchone()
            if row is None:
                conn.execute("ROLLBACK")
                return None
            now = datetime.now(timezone.utc).isoformat()
            conn.execute(
                "UPDATE tasks SET status = ?, started_at = ? WHERE task_id = ?",
                (TaskStatus.RUNNING.value, now, row["task_id"]),
            )
            conn.execute("COMMIT")
            task = Task.from_row(row)
            task.status = TaskStatus.RUNNING
            task.started_at = now
            logger.info(f"Task claimed: {task.task_id}")
            return task

    def update_status(
        self,
        task_id: str,
        status: TaskStatus,
        *,
        error_message: Optional[str] = None,
        pr_url: Optional[str] = None,
        container_id: Optional[str] = None,
    ):
        fields = ["status = ?"]
        values: list = [status.value]

        if status in (TaskStatus.COMPLETED, TaskStatus.FAILED):
            fields.append("completed_at = ?")
            values.append(datetime.now(timezone.utc).isoformat())
        if error_message is not None:
            fields.append("error_message = ?")
            values.append(error_message)
        if pr_url is not None:
            fields.append("pr_url = ?")
            values.append(pr_url)
        if container_id is not None:
            fields.append("container_id = ?")
            values.append(container_id)

        values.append(task_id)
        sql = f"UPDATE tasks SET {', '.join(fields)} WHERE task_id = ?"
        with self._connect() as conn:
            conn.execute(sql, values)
            conn.commit()
        logger.info(f"Task {task_id} → {status.value}")

    def count_running(self) -> int:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT COUNT(*) FROM tasks WHERE status IN (?,?,?)",
                (TaskStatus.RUNNING.value, TaskStatus.TESTING.value, TaskStatus.REVIEWING.value),
            ).fetchone()
            return row[0]

    def list_tasks(self, status: Optional[TaskStatus] = None) -> list[Task]:
        with self._connect() as conn:
            if status:
                rows = conn.execute(
                    "SELECT * FROM tasks WHERE status = ? ORDER BY created_at DESC",
                    (status.value,),
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT * FROM tasks ORDER BY created_at DESC"
                ).fetchall()
            return [Task.from_row(r) for r in rows]

    def get_task(self, task_id: str) -> Optional[Task]:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM tasks WHERE task_id = ?", (task_id,)
            ).fetchone()
            return Task.from_row(row) if row else None
