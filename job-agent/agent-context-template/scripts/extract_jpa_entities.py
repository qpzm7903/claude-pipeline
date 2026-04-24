#!/usr/bin/env python3
"""
扫描 Java 源码中的 JPA 实体，生成 entity-graph.md 的 AUTO-GENERATED 区骨架。

用法:
    python3 extract_jpa_entities.py --src service-a/src/main/java --out .agent-context/entity-graph.md

策略:
    - 纯 stdlib (re + pathlib)，不依赖 javaparser
    - 只抓关键注解: @Entity, @Table, @Column, @Id, @OneToMany, @ManyToOne, @OneToOne, @ManyToMany
    - 生成骨架供人工补全业务语义
    - 刷新时只替换 <!-- BEGIN AUTO-GENERATED --> ... <!-- END AUTO-GENERATED --> 区间
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

ENTITY_RE = re.compile(r"@Entity\b")
TABLE_RE = re.compile(r'@Table\s*\(\s*name\s*=\s*"([^"]+)"')
CLASS_RE = re.compile(r"(?:public\s+)?class\s+(\w+)")
PACKAGE_RE = re.compile(r"^\s*package\s+([\w\.]+)\s*;", re.MULTILINE)
ID_RE = re.compile(r"@Id\b")
COLUMN_RE = re.compile(r'@Column\s*\(\s*(?:name\s*=\s*"([^"]+)")?')
FIELD_DECL_RE = re.compile(r"(?:private|protected|public)\s+(\w+(?:<[^>]+>)?)\s+(\w+)\s*(?:=|;)")
RELATION_RE = re.compile(r"@(OneToOne|OneToMany|ManyToOne|ManyToMany)\b")

AUTO_BEGIN = "<!-- BEGIN AUTO-GENERATED -->"
AUTO_END = "<!-- END AUTO-GENERATED -->"


@dataclass
class JpaField:
    name: str
    java_type: str
    column: Optional[str] = None
    is_id: bool = False
    relation: Optional[str] = None


@dataclass
class JpaEntity:
    class_name: str
    package: str
    file_path: str
    table: Optional[str] = None
    fields: list[JpaField] = field(default_factory=list)

    @property
    def fqn(self) -> str:
        return f"{self.package}.{self.class_name}"


def parse_file(path: Path) -> Optional[JpaEntity]:
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = path.read_text(encoding="latin-1")

    if not ENTITY_RE.search(text):
        return None

    pkg_m = PACKAGE_RE.search(text)
    cls_m = CLASS_RE.search(text)
    if not cls_m:
        return None

    entity = JpaEntity(
        class_name=cls_m.group(1),
        package=pkg_m.group(1) if pkg_m else "(default)",
        file_path=str(path),
    )

    table_m = TABLE_RE.search(text)
    if table_m:
        entity.table = table_m.group(1)

    # 按行扫描字段 —— 累积注解，遇到字段声明时落盘
    pending_annotations: list[str] = []
    pending_column: Optional[str] = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        if stripped.startswith("@"):
            pending_annotations.append(stripped)
            col_m = COLUMN_RE.search(stripped)
            if col_m and col_m.group(1):
                pending_column = col_m.group(1)
            continue

        fd = FIELD_DECL_RE.search(stripped)
        if fd and pending_annotations:
            annotations_blob = " ".join(pending_annotations)
            rel_m = RELATION_RE.search(annotations_blob)
            entity.fields.append(
                JpaField(
                    name=fd.group(2),
                    java_type=fd.group(1),
                    column=pending_column,
                    is_id=bool(ID_RE.search(annotations_blob)),
                    relation=rel_m.group(1) if rel_m else None,
                )
            )
            pending_annotations.clear()
            pending_column = None
        elif not stripped.startswith("//"):
            # 非注解、非字段声明（方法、注释、等），清空累积
            if ";" in stripped or "{" in stripped or "}" in stripped:
                pending_annotations.clear()
                pending_column = None

    return entity


def render(entities: list[JpaEntity]) -> str:
    lines: list[str] = [
        "",
        f"_本区由 `extract_jpa_entities.py` 自动生成于刷新时。_",
        f"_JPA 实体共 **{len(entities)}** 个。_",
        "",
    ]
    for e in sorted(entities, key=lambda x: x.fqn):
        lines.append(f"### {e.class_name} _(JPA)_")
        lines.append("")
        lines.append(f"- **FQN**：`{e.fqn}`")
        lines.append(f"- **表名**：`{e.table or '(未标 @Table)'}`")
        lines.append(f"- **代码路径**：`{e.file_path}`")
        ids = [f for f in e.fields if f.is_id]
        if ids:
            lines.append(f"- **主键**：{', '.join(f.name for f in ids)}")
        relations = [f for f in e.fields if f.relation]
        if relations:
            lines.append("- **关系（自动检测）**：")
            for f in relations:
                lines.append(f"  - {f.relation} → `{f.java_type}`（字段 `{f.name}`）")
        lines.append(f"- **字段数**：{len(e.fields)}")
        lines.append("- **业务含义**：_(待人工补)_")
        lines.append("- **生命周期**：_(待人工补)_")
        lines.append("")
    return "\n".join(lines)


def replace_auto_section(doc_path: Path, new_content: str) -> None:
    if not doc_path.exists():
        doc_path.write_text(
            f"# 实体关系图\n\n{AUTO_BEGIN}\n{new_content}\n{AUTO_END}\n", encoding="utf-8"
        )
        return

    text = doc_path.read_text(encoding="utf-8")
    if AUTO_BEGIN not in text or AUTO_END not in text:
        raise SystemExit(
            f"❌ {doc_path} 中缺少 {AUTO_BEGIN} / {AUTO_END} 标记，拒绝刷新。"
            "请先在目标文件内加回标记（参考 service-level/.agent-context/entity-graph.md）。"
        )

    pattern = re.compile(
        re.escape(AUTO_BEGIN) + r".*?" + re.escape(AUTO_END), re.DOTALL
    )
    replaced = pattern.sub(f"{AUTO_BEGIN}\n{new_content}\n{AUTO_END}", text)
    doc_path.write_text(replaced, encoding="utf-8")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--src", required=True, help="Java 源码根目录（如 service-a/src/main/java）")
    p.add_argument("--out", required=True, help="目标 entity-graph.md 路径")
    args = p.parse_args()

    src_root = Path(args.src)
    if not src_root.is_dir():
        print(f"❌ src 目录不存在: {src_root}", file=sys.stderr)
        return 2

    entities: list[JpaEntity] = []
    for java_file in src_root.rglob("*.java"):
        e = parse_file(java_file)
        if e:
            entities.append(e)

    body = render(entities)
    replace_auto_section(Path(args.out), body)
    print(f"✅ 写入 {args.out} —— JPA 实体 {len(entities)} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
