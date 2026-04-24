#!/usr/bin/env python3
"""
扫描 MyBatis Mapper（Java @Mapper 接口 + XML），生成 entity-graph.md 里 MyBatis 区的骨架。

策略:
    - MyBatis 的实体关系藏在 SQL 里，无法自动推导关系图
    - 本脚本只生成 "Mapper 清单 + 操作清单" 的骨架
    - 关系、业务含义、生命周期必须人工补到 HUMAN-CURATED 区
    - 目的是让 agent 至少知道"这个服务有哪些 Mapper、每个 Mapper 有哪些操作"

用法:
    python3 extract_mybatis_mappers.py \
        --java-src service-a/src/main/java \
        --xml-src  service-a/src/main/resources/mapper \
        --out      .agent-context/entity-graph.md
"""
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

MAPPER_ANN_RE = re.compile(r"@Mapper\b")
INTERFACE_RE = re.compile(r"(?:public\s+)?interface\s+(\w+)")
PACKAGE_RE = re.compile(r"^\s*package\s+([\w\.]+)\s*;", re.MULTILINE)

# 抓 Java 注解里的 SQL（@Select / @Insert / @Update / @Delete）
SQL_ANN_RE = re.compile(
    r"@(Select|Insert|Update|Delete)\s*\(\s*(?:value\s*=\s*)?\{?\s*\"(.+?)\"",
    re.DOTALL,
)
METHOD_RE = re.compile(r"\b(?:public|default)?\s*\w[\w<>\[\],\s\?]*\s+(\w+)\s*\(")

AUTO_BEGIN_MB = "<!-- BEGIN AUTO-GENERATED-MYBATIS -->"
AUTO_END_MB = "<!-- END AUTO-GENERATED-MYBATIS -->"


@dataclass
class MapperOp:
    name: str
    kind: str  # select / insert / update / delete
    source: str  # java-annotation / xml


@dataclass
class MyBatisMapper:
    class_name: str
    package: str
    file_path: str
    xml_path: Optional[str] = None
    ops: list[MapperOp] = field(default_factory=list)

    @property
    def fqn(self) -> str:
        return f"{self.package}.{self.class_name}"


def parse_java_mapper(path: Path) -> Optional[MyBatisMapper]:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = path.read_text(encoding="latin-1")

    if not MAPPER_ANN_RE.search(text):
        # 也可能没注解但通过 xml 扫描到，先跳过接口无 @Mapper 的情况
        return None

    iface_m = INTERFACE_RE.search(text)
    if not iface_m:
        return None

    pkg_m = PACKAGE_RE.search(text)
    mapper = MyBatisMapper(
        class_name=iface_m.group(1),
        package=pkg_m.group(1) if pkg_m else "(default)",
        file_path=str(path),
    )

    for m in SQL_ANN_RE.finditer(text):
        kind = m.group(1).lower()
        # 找 SQL 注解之后紧邻的方法名
        tail = text[m.end():]
        meth = METHOD_RE.search(tail)
        if meth:
            mapper.ops.append(MapperOp(name=meth.group(1), kind=kind, source="java-annotation"))

    return mapper


def parse_xml_mapper(xml_path: Path) -> Optional[tuple[str, list[MapperOp]]]:
    try:
        tree = ET.parse(xml_path)
    except ET.ParseError:
        return None
    root = tree.getroot()
    if root.tag != "mapper":
        return None
    namespace = root.attrib.get("namespace")
    if not namespace:
        return None

    ops: list[MapperOp] = []
    for child in root:
        if child.tag in ("select", "insert", "update", "delete"):
            op_id = child.attrib.get("id")
            if op_id:
                ops.append(MapperOp(name=op_id, kind=child.tag, source="xml"))
    return namespace, ops


def render(mappers: list[MyBatisMapper]) -> str:
    lines: list[str] = [
        "",
        f"_本区由 `extract_mybatis_mappers.py` 自动生成于刷新时。_",
        f"_MyBatis Mapper 共 **{len(mappers)}** 个。_",
        "",
        "> ⚠️ MyBatis 的实体关系藏在 SQL 里，本脚本**不推导关系**。",
        "> 关系、业务含义、生命周期必须人工补到 HUMAN-CURATED 区。",
        "",
    ]
    for m in sorted(mappers, key=lambda x: x.fqn):
        lines.append(f"### {m.class_name} _(MyBatis Mapper)_")
        lines.append("")
        lines.append(f"- **FQN**：`{m.fqn}`")
        lines.append(f"- **Java 路径**：`{m.file_path}`")
        if m.xml_path:
            lines.append(f"- **XML 路径**：`{m.xml_path}`")
        lines.append(f"- **操作数**：{len(m.ops)}")
        if m.ops:
            by_kind: dict[str, list[str]] = {}
            for op in m.ops:
                by_kind.setdefault(op.kind, []).append(op.name)
            for kind in ("select", "insert", "update", "delete"):
                if kind in by_kind:
                    names = ", ".join(sorted(set(by_kind[kind])))
                    lines.append(f"  - `{kind}`: {names}")
        lines.append("- **业务含义**：_(待人工补)_")
        lines.append("- **关联实体**：_(待人工补，需要读 SQL 判断)_")
        lines.append("")
    return "\n".join(lines)


def replace_auto_section(doc_path: Path, new_content: str) -> None:
    if not doc_path.exists():
        doc_path.write_text(
            f"# 实体关系图\n\n{AUTO_BEGIN_MB}\n{new_content}\n{AUTO_END_MB}\n",
            encoding="utf-8",
        )
        return

    text = doc_path.read_text(encoding="utf-8")
    if AUTO_BEGIN_MB not in text or AUTO_END_MB not in text:
        # 兼容：如果文件里只有通用的 AUTO-GENERATED 标记，追加 MyBatis 专用区
        generic_begin = "<!-- BEGIN AUTO-GENERATED -->"
        generic_end = "<!-- END AUTO-GENERATED -->"
        if generic_begin in text and generic_end in text:
            text = text.replace(
                generic_end,
                f"{generic_end}\n\n{AUTO_BEGIN_MB}\n{new_content}\n{AUTO_END_MB}",
            )
            doc_path.write_text(text, encoding="utf-8")
            return
        raise SystemExit(
            f"❌ {doc_path} 中缺少 {AUTO_BEGIN_MB} / {AUTO_END_MB} 标记，拒绝刷新。"
        )

    pattern = re.compile(
        re.escape(AUTO_BEGIN_MB) + r".*?" + re.escape(AUTO_END_MB), re.DOTALL
    )
    replaced = pattern.sub(f"{AUTO_BEGIN_MB}\n{new_content}\n{AUTO_END_MB}", text)
    doc_path.write_text(replaced, encoding="utf-8")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--java-src", required=True, help="Java 源码根目录")
    p.add_argument("--xml-src", required=True, help="MyBatis XML 根目录")
    p.add_argument("--out", required=True, help="entity-graph.md 路径")
    args = p.parse_args()

    java_root = Path(args.java_src)
    xml_root = Path(args.xml_src)

    mappers: dict[str, MyBatisMapper] = {}

    if java_root.is_dir():
        for java_file in java_root.rglob("*.java"):
            m = parse_java_mapper(java_file)
            if m:
                mappers[m.fqn] = m

    if xml_root.is_dir():
        for xml_file in xml_root.rglob("*.xml"):
            parsed = parse_xml_mapper(xml_file)
            if not parsed:
                continue
            namespace, ops = parsed
            if namespace in mappers:
                mappers[namespace].xml_path = str(xml_file)
                mappers[namespace].ops.extend(ops)
            else:
                # XML 存在但 Java 接口未被扫到（比如接口没标 @Mapper，通过 MapperScan 扫描）
                pkg = ".".join(namespace.split(".")[:-1]) or "(default)"
                cls = namespace.split(".")[-1]
                mappers[namespace] = MyBatisMapper(
                    class_name=cls,
                    package=pkg,
                    file_path="(未找到 @Mapper 注解的 Java 接口，可能通过 @MapperScan 扫描)",
                    xml_path=str(xml_file),
                    ops=list(ops),
                )

    body = render(list(mappers.values()))
    replace_auto_section(Path(args.out), body)
    print(f"✅ 写入 {args.out} —— MyBatis Mapper {len(mappers)} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
