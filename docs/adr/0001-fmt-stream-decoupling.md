# ADR-0001: fmt_stream.py 与 Claude 进程解耦

**日期**：2026-03-16
**状态**：部分实施（方案 A 已上线，方案 C 待实施）
**决策者**：weiyicheng

---

## 背景

`fmt_stream.py` 是 `entrypoint.sh` 中内嵌的日志格式化器，负责将 `claude` CLI 的 `--output-format stream-json` 输出转换为人类可读的彩色日志。

当前架构：

```
claude --output-format stream-json ... 2>&1 | _fmt_stream()
                                                    ↓
                                          python3 fmt_stream.py
                                                    ↓
                                          容器 stdout → kubectl logs
```

`fmt_stream.py` 处于 Claude 进程的**关键路径**（管道写端）。

## 触发事件

2026-03-16，Pod `claude-pipeline-prompt-deiven-29560920-629qp` 在运行 113 分钟后 OOMKilled。根因链：

1. Claude 调用 Agent（Explore 子代理），tool_result 返回 `content` 为 `list` 类型
2. `fmt_stream.py` 对 `list` 调用 `.splitlines()` → `AttributeError` → 进程退出
3. 管道读端关闭，Claude 写入时收到 SIGPIPE，但 Claude 进程**未立即退出**，继续在内存中运行
4. 无日志输出，内存持续累积（大型 Rust 项目分析 + 3 个 Explore 子代理并发）
5. 113 分钟后触发节点 OOM Killer（节点可分配内存 7.55 GiB，容器 limit 配置错误为 8 GiB）

## 决策

### 方案 A（已实施，2026-03-16）：让 fmt_stream.py 永不崩溃

将处理逻辑提取为 `process(obj)` 函数，主循环用 `try/except Exception: pass` 包裹，
任何未预期的数据类型或格式错误均跳过当前行，继续处理下一行。

```python
def process(obj):
    # 全部格式化逻辑

for raw in sys.stdin:
    ...
    try:
        process(obj)
    except Exception:
        pass  # 跳过，不退出
```

**优点**：改动极小（2 行），立即上线
**缺点**：fmt_stream.py 仍在关键路径，只是不会崩溃了；如果 Python 进程因其他原因（OOM、信号）退出，管道仍会断裂

---

### 方案 C（待实施）：彻底解耦，后台异步格式化

将 `claude` 的输出写入临时文件，`fmt_stream.py` 作为独立后台进程消费该文件，两者完全解耦：

```bash
# claude 只写文件，不管格式化
claude ... > /tmp/claude-raw.jsonl 2>&1 &
CLAUDE_PID=$!

# 独立后台进程负责展示，崩了对 claude 零影响
tail -f /tmp/claude-raw.jsonl | python3 -u /tmp/fmt_stream.py &

wait $CLAUDE_PID
CLAUDE_EXIT=$?

# 给 fmt_stream 时间刷完最后几行
sleep 1
kill %2 2>/dev/null

exit $CLAUDE_EXIT
```

**优点**：
- fmt_stream.py 任何崩溃都不影响 Claude 执行
- Claude 退出码干净（不受管道污染）
- 原始 JSON 落盘，可事后分析

**缺点**：
- `/tmp/claude-raw.jsonl` 会随时间增长，需清理（或限制大小）
- `tail -f` + 后台 kill 的时序需仔细处理，避免最后几行丢失
- 改动比方案 A 大，需要测试

## 实施计划

- [x] **方案 A**：2026-03-16 上线，随新镜像 `sha256:4ce58f82b6ef` 生效
- [ ] **方案 C**：下一个迭代实施，替换 `entrypoint.sh` 中的 `_fmt_stream()` 函数和调用方式

## 附：同期修复

- `fmt_stream.py` content 类型检查（`isinstance(content, list)`）：修复触发此事件的具体 bug
- K8s 内存 limit 从 8Gi 调整为 6Gi：节点可分配内存仅 7.55 GiB，原配置导致 cgroup limit 无效
