#!/usr/bin/env python3
"""
扫描 @RestController / @Controller，生成 api-contracts.md 的 AUTO-GENERATED 骨架。

用法:
    python3 extract_api_contracts.py --src service-a/src/main/java --out .agent-context/api-contracts.md

策略:
    - 纯 stdlib，不依赖 javaparser
    - 抓 @RestController / @Controller / @RequestMapping / @GetMapping / @PostMapping / @PutMapping / @DeleteMapping / @PatchMapping
    - 生成 (method, path, controller#method) 清单；业务含义、鉴权、错误码由人工补
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

CONTROLLER_RE = re.compile(r"@(RestController|Controller)\b")
PACKAGE_RE = re.compile(r"^\s*package\s+([\w\.]+)\s*;", re.MULTILINE)
CLASS_RE = re.compile(r"(?:public\s+)?class\s+(\w+)")
CLASS_MAPPING_RE = re.compile(
    r'@RequestMapping\s*\(\s*(?:value\s*=\s*|path\s*=\s*)?"?([^")]*)'
)
# 只匹配方法级的映射注解；@RequestMapping 专用于类级，避免与 CLASS_MAPPING_RE 冲突。
# 允许无括号形式（如 `@PostMapping` 单独一行），group 2 在此情形为 None。
METHOD_ANN_RE = re.compile(
    r'@(Get|Post|Put|Delete|Patch)Mapping\b'
    r'(?:\s*\(\s*(?:value\s*=\s*|path\s*=\s*)?"?([^"),]*))?'
)
METHOD_NAME_RE = re.compile(r"\b(?:public)\s+\S[\S\s]*?\s+(\w+)\s*\(")

AUTO_BEGIN = "<!-- BEGIN AUTO-GENERATED -->"
AUTO_END = "<!-- END AUTO-GENERATED -->"


@dataclass
class Endpoint:
    http_method: str
    path: str
    controller_fqn: str
    method_name: str


@dataclass
class ControllerInfo:
    class_name: str
    package: str
    base_path: str
    file_path: str
    endpoints: list[Endpoint] = field(default_factory=list)

    @property
    def fqn(self) -> str:
        return f"{self.package}.{self.class_name}"


def parse_file(path: Path) -> Optional[ControllerInfo]:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = path.read_text(encoding="latin-1")

    if not CONTROLLER_RE.search(text):
        return None

    pkg_m = PACKAGE_RE.search(text)
    cls_m = CLASS_RE.search(text)
    if not cls_m:
        return None

    ci = ControllerInfo(
        class_name=cls_m.group(1),
        package=pkg_m.group(1) if pkg_m else "(default)",
        base_path="",
        file_path=str(path),
    )

    # 只取类上的第一个 @RequestMapping 作为 base path（不区分字段位置）
    cls_mapping = CLASS_MAPPING_RE.search(text)
    if cls_mapping:
        ci.base_path = cls_mapping.group(1).strip("/")

    # 按行累积注解到方法签名
    pending: list[tuple[str, str]] = []  # (http_method, path)
    for line in text.splitlines():
        s = line.strip()
        if not s:
            continue

        m = METHOD_ANN_RE.search(s)
        if m:
            http = m.group(1).upper()
            path_part = (m.group(2) or "").strip("/")
            pending.append((http, path_part))
            continue

        meth = METHOD_NAME_RE.search(s)
        if meth and pending:
            for http, path_part in pending:
                full_path = "/" + "/".join(
                    p for p in [ci.base_path, path_part] if p
                )
                ci.endpoints.append(
                    Endpoint(
                        http_method=http,
                        path=full_path,
                        controller_fqn=ci.fqn,
                        method_name=meth.group(1),
                    )
                )
            pending.clear()

    return ci if ci.endpoints else None


def render(controllers: list[ControllerInfo]) -> str:
    total = sum(len(c.endpoints) for c in controllers)
    lines: list[str] = [
        "",
        f"_本区由 `extract_api_contracts.py` 自动生成于刷新时。_",
        f"_Controller **{len(controllers)}** 个，Endpoint **{total}** 个。_",
        "",
    ]
    for c in sorted(controllers, key=lambda x: x.fqn):
        lines.append(f"### {c.class_name}")
        lines.append(f"- **FQN**：`{c.fqn}`")
        lines.append(f"- **路径**：`{c.file_path}`")
        lines.append(f"- **Base**：`/{c.base_path or ''}`")
        lines.append("- **Endpoints**：")
        for ep in sorted(c.endpoints, key=lambda e: (e.path, e.http_method)):
            lines.append(f"  - `{ep.http_method} {ep.path}` → `{ep.method_name}`")
        lines.append("")
    return "\n".join(lines)


def replace_auto_section(doc_path: Path, new_content: str) -> None:
    if not doc_path.exists():
        doc_path.write_text(
            f"# 对外 API 契约\n\n{AUTO_BEGIN}\n{new_content}\n{AUTO_END}\n",
            encoding="utf-8",
        )
        return
    text = doc_path.read_text(encoding="utf-8")
    if AUTO_BEGIN not in text or AUTO_END not in text:
        raise SystemExit(f"❌ {doc_path} 缺少标记 {AUTO_BEGIN}/{AUTO_END}，拒绝刷新。")
    pattern = re.compile(
        re.escape(AUTO_BEGIN) + r".*?" + re.escape(AUTO_END), re.DOTALL
    )
    replaced = pattern.sub(f"{AUTO_BEGIN}\n{new_content}\n{AUTO_END}", text)
    doc_path.write_text(replaced, encoding="utf-8")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--src", required=True)
    p.add_argument("--out", required=True)
    args = p.parse_args()

    src_root = Path(args.src)
    if not src_root.is_dir():
        print(f"❌ src 目录不存在: {src_root}", file=sys.stderr)
        return 2

    controllers: list[ControllerInfo] = []
    for f in src_root.rglob("*.java"):
        c = parse_file(f)
        if c:
            controllers.append(c)

    body = render(controllers)
    replace_auto_section(Path(args.out), body)
    total = sum(len(c.endpoints) for c in controllers)
    print(f"✅ 写入 {args.out} —— Controller {len(controllers)} 个, Endpoint {total} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
