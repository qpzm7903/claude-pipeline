#!/usr/bin/env bash
# 组合入口：同时刷新 entity-graph.md (JPA + MyBatis) 和 api-contracts.md
#
# 用法:
#   ./generate_entity_graph.sh <service-dir> <agent-context-dir>
#
# 示例:
#   ./generate_entity_graph.sh service-a service-a/.agent-context

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "用法: $0 <service-dir> <agent-context-dir>" >&2
  exit 2
fi

SERVICE_DIR="$1"
CTX_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JAVA_SRC="$SERVICE_DIR/src/main/java"
XML_SRC="$SERVICE_DIR/src/main/resources/mapper"

if [[ ! -d "$JAVA_SRC" ]]; then
  echo "⚠️  未找到 $JAVA_SRC —— 可能是多模块项目，请直接调用各子脚本指定精确路径" >&2
fi

mkdir -p "$CTX_DIR"

# JPA 实体
python3 "$SCRIPT_DIR/extract_jpa_entities.py" \
  --src "$JAVA_SRC" \
  --out "$CTX_DIR/entity-graph.md"

# MyBatis Mapper（XML 目录不存在时跳过 XML 侧）
if [[ -d "$XML_SRC" ]] || [[ -d "$JAVA_SRC" ]]; then
  python3 "$SCRIPT_DIR/extract_mybatis_mappers.py" \
    --java-src "$JAVA_SRC" \
    --xml-src "$XML_SRC" \
    --out "$CTX_DIR/entity-graph.md"
fi

# Controller API
python3 "$SCRIPT_DIR/extract_api_contracts.py" \
  --src "$JAVA_SRC" \
  --out "$CTX_DIR/api-contracts.md"

echo "✅ 完成。下一步：人工填补 HUMAN-CURATED 区的业务含义。"
