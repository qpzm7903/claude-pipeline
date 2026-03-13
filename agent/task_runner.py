"""
task_runner.py - 按 phase 构建 Claude 提示词

在容器内运行，从环境变量读取任务信息，
根据 --phase 参数生成对应 Agent 的提示词，输出到 stdout。

用法:
  python task_runner.py --phase tdd > tdd_prompt.md
  python task_runner.py --phase coding --retry 1 > coding_prompt.md
  python task_runner.py --phase review > review_prompt.md
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from textwrap import dedent


def get_task() -> dict:
    """从环境变量读取任务 JSON。"""
    task_json = os.environ.get("TASK_JSON", "{}")
    return json.loads(task_json)


def get_repo_tree(workspace: str = "/workspace", max_files: int = 60) -> str:
    """生成仓库文件结构概览（排除常见无关目录）。"""
    excludes = [
        ".git", "__pycache__", "node_modules", ".venv", "venv",
        "dist", "build", ".mypy_cache", ".pytest_cache", "*.pyc",
    ]
    exclude_args = []
    for ex in excludes:
        exclude_args.extend(["-not", "-path", f"*/{ex}/*"])

    try:
        result = subprocess.run(
            ["find", workspace, "-type", "f"] + exclude_args,
            capture_output=True,
            text=True,
            timeout=10,
        )
        lines = result.stdout.strip().splitlines()
        # 相对路径 + 截断
        rel_lines = [
            line.replace(workspace, ".") for line in lines[:max_files]
        ]
        if len(lines) > max_files:
            rel_lines.append(f"... (showing {max_files}/{len(lines)} files)")
        return "\n".join(rel_lines)
    except Exception as e:
        return f"(Unable to generate tree: {e})"


def get_test_results(workspace: str = "/workspace") -> str:
    """运行测试并捕获输出（用于 coding retry 时的错误信息）。"""
    test_cmd = os.environ.get("TEST_COMMAND", "pytest")
    try:
        result = subprocess.run(
            test_cmd.split(),
            capture_output=True,
            text=True,
            timeout=120,
            cwd=workspace,
        )
        output = result.stdout + result.stderr
        # 截取最后2000个字符（通常包含失败信息）
        return output[-2000:] if len(output) > 2000 else output
    except subprocess.TimeoutExpired:
        return "(Test command timed out)"
    except Exception as e:
        return f"(Could not run tests: {e})"


def build_tdd_prompt(task: dict, workspace: str) -> str:
    """
    TDD Agent 提示词 - 角色: 测试工程师
    目标: 根据 SPEC 编写完整测试，不写实现代码
    """
    repo_tree = get_repo_tree(workspace)
    spec = task.get("spec_content", "").strip() or "(No spec provided - infer from task description)"
    language = task.get("language", "python")

    test_framework_hint = {
        "python": "pytest（测试文件命名: test_*.py）",
        "node": "jest（测试文件命名: *.test.js 或 *.spec.js）",
        "java": "JUnit 5（测试文件命名: *Test.java）",
    }.get(language, "适合该语言的测试框架")

    return dedent(f"""
    # 角色定义

    你是一名专业的**测试工程师**，负责根据需求规格编写测试用例。

    **核心约束**:
    1. 你**只能**编写测试代码，**禁止**编写任何实现代码
    2. 测试此时应全部失败（因为还没有实现） - 这是 TDD 的正常状态
    3. 测试必须覆盖: 正常路径、边界条件、错误情况
    4. 使用 {test_framework_hint}

    ---

    # 任务信息

    **任务 ID**: {task.get('task_id', 'unknown')}
    **任务标题**: {task.get('title', 'unknown')}
    **任务描述**: {task.get('description', '')}

    ---

    # 需求规格 (SPEC)

    {spec}

    ---

    # 当前仓库结构

    ```
    {repo_tree}
    ```

    ---

    # 执行指令

    请根据以上需求规格，**只编写测试代码**:

    1. 分析 SPEC，识别所有需要测试的功能点
    2. 为每个功能点编写测试用例（包括正常流程、边界值、异常处理）
    3. 将测试写入合适的测试文件中
    4. 测试应使用清晰的命名，能自文档化测试意图

    **注意**: 暂时不要实现被测试的功能，只写测试。
    """).strip()


def build_coding_prompt(task: dict, workspace: str, retry: int = 0) -> str:
    """
    Coding Agent 提示词 - 角色: 开发工程师
    目标: 实现代码让所有测试通过
    """
    repo_tree = get_repo_tree(workspace)
    spec = task.get("spec_content", "").strip()
    language = task.get("language", "python")
    test_cmd = task.get("test_command", "pytest")

    # 重试时附上上次的错误信息
    error_context = ""
    if retry > 0:
        test_output = get_test_results(workspace)
        error_context = dedent(f"""
        ---

        # 上次测试结果（第 {retry} 次重试）

        以下是上次运行 `{test_cmd}` 的输出，分析失败原因并修复:

        ```
        {test_output}
        ```
        """).strip()

    retry_label = f"（第 {retry + 1} 次尝试）" if retry > 0 else ""

    return dedent(f"""
    # 角色定义 {retry_label}

    你是一名专业的**软件开发工程师**，你的唯一目标是**让所有测试通过**。

    **核心约束**:
    1. **禁止修改任何测试文件**（test_*.py / *.test.js / *Test.java）
    2. 只实现使测试通过所必需的代码，不要过度设计
    3. 代码应遵循 {language} 最佳实践
    4. 运行 `{test_cmd}` 验证所有测试通过

    ---

    # 任务信息

    **任务 ID**: {task.get('task_id', 'unknown')}
    **任务标题**: {task.get('title', 'unknown')}

    ---

    # 需求规格 (SPEC)

    {spec if spec else "(参考测试文件推断需求)"}

    ---

    # 当前仓库结构

    ```
    {repo_tree}
    ```

    {error_context}

    ---

    # 执行指令

    1. 阅读所有测试文件，理解每个测试的期望行为
    2. 实现使所有测试通过的代码
    3. 确保不修改任何测试文件
    4. 实现完成后，运行 `{test_cmd}` 确认全部通过

    记住: **测试是需求的唯一权威**，测试说什么行为是正确的，你就实现什么。
    """).strip()


def build_review_prompt(task: dict, workspace: str) -> str:
    """
    Review Agent 提示词 - 角色: 代码审查员
    目标: 审查代码质量，输出结构化 JSON 报告
    """
    repo_tree = get_repo_tree(workspace)
    language = task.get("language", "python")

    return dedent(f"""
    # 角色定义

    你是一名经验丰富的**代码审查员**，负责评估代码的质量、安全性和可维护性。

    **审查维度**:
    1. **正确性**: 实现是否符合需求规格？是否有逻辑错误？
    2. **安全性**: 是否存在注入漏洞、不安全的依赖、敏感信息泄露等风险？
    3. **可维护性**: 代码结构是否清晰？命名是否语义化？是否有适当注释？
    4. **性能**: 是否有明显的性能问题（O(n²) 循环、重复查询等）？
    5. **测试覆盖**: 测试是否充分覆盖了核心场景和边界条件？

    ---

    # 任务信息

    **任务 ID**: {task.get('task_id', 'unknown')}
    **任务标题**: {task.get('title', 'unknown')}
    **编程语言**: {language}

    ---

    # 仓库结构

    ```
    {repo_tree}
    ```

    ---

    # 执行指令

    请审查此次提交中修改的代码文件，然后**必须**将审查结果输出为以下 JSON 格式，
    并将 JSON 保存到文件 `/workspace/review_result.json`:

    ```json
    {{
      "task_id": "{task.get('task_id', 'unknown')}",
      "verdict": "pass",
      "score": 85,
      "summary": "简要总结（1-2句话）",
      "issues": [
        {{
          "severity": "high|medium|low",
          "category": "security|correctness|performance|maintainability",
          "file": "相对文件路径",
          "line": 42,
          "description": "问题描述",
          "suggestion": "改进建议"
        }}
      ],
      "strengths": ["做得好的方面1", "做得好的方面2"],
      "recommendation": "approve|request_changes"
    }}
    ```

    **verdict 规则**:
    - `"pass"`: 无 high severity 问题
    - `"fail"`: 存在任何 high severity 问题

    **重要**: 输出 JSON 文件后，在终端打印 `REVIEW_COMPLETE` 表示完成。
    """).strip()


def main():
    parser = argparse.ArgumentParser(description="Build Claude prompts for pipeline phases")
    parser.add_argument(
        "--phase",
        required=True,
        choices=["tdd", "coding", "review"],
        help="Pipeline phase to generate prompt for",
    )
    parser.add_argument(
        "--retry",
        type=int,
        default=0,
        help="Retry attempt number (for coding phase)",
    )
    parser.add_argument(
        "--workspace",
        default="/workspace",
        help="Path to the workspace directory",
    )
    args = parser.parse_args()

    task = get_task()
    workspace = args.workspace

    if args.phase == "tdd":
        prompt = build_tdd_prompt(task, workspace)
    elif args.phase == "coding":
        prompt = build_coding_prompt(task, workspace, retry=args.retry)
    elif args.phase == "review":
        prompt = build_review_prompt(task, workspace)
    else:
        print(f"Unknown phase: {args.phase}", file=sys.stderr)
        sys.exit(1)

    print(prompt)


if __name__ == "__main__":
    main()
