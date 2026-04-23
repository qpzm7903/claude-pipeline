#!/usr/bin/env bash
# build.sh — 集成脚本
#
# 将分离的 prompt 模块 + job-template.yml 合并为单文件 YAML，
# 直接复制到 K8s 即可执行。
#
# 用法:
#   ./build.sh --task ut-gen --job-name xdm-f-core-ut \
#     --repo "git clone http://user:pass@host/repo.git" \
#     --model maas-glm-5-aliyun-codeagent
#
#   ./build.sh --task refactor --job-name xdm-refactor \
#     --repo "git clone http://user:pass@host/repo.git" \
#     --output dist/xdm-refactor.yml
#
#   ./build.sh --list   # 列出所有可用任务类型

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROMPTS_DIR="${_SCRIPT_DIR}/prompts"
_TEMPLATE="${_SCRIPT_DIR}/job-template.yml"

# ── 默认值 ────────────────────────────────────────────────────────
TASK=""
JOB_NAME=""
REPO_CLONE_CMD=""
MODEL="maas-glm-5-aliyun-codeagent"
OPENAI_BASE_URL="http://10.58.236.242:4000/v1"
OPENAI_API_KEY="sk-1234"
IMAGE="swr.cn-north-5.myhuaweicloud.com/token/gsc-tool-image:qwen-code-26.2.x_20260417_173923_d16de7f-x86_64"
NODE="192.168.0.219"
TIMEOUT="7200"
SLEEP_TIME="600"
COMPLETIONS="20"
PARALLELISM="1"
OUTPUT=""

# ── 可用任务类型 ──────────────────────────────────────────────────
AVAILABLE_TASKS=("ut-gen" "feature-dev" "refactor" "perf-optimize" "bug-fix")

# ── 帮助信息 ──────────────────────────────────────────────────────
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

必选参数:
  --task <type>         任务类型 (${AVAILABLE_TASKS[*]})
  --job-name <name>     K8s Job 名称
  --repo <clone_cmd>    仓库克隆命令

可选参数:
  --model <model>       模型名称 (默认: ${MODEL})
  --base-url <url>      OpenAI API Base URL (默认: ${OPENAI_BASE_URL})
  --api-key <key>       OpenAI API Key (默认: ${OPENAI_API_KEY})
  --image <image>       Docker 镜像 (默认: 使用模板中的镜像)
  --node <ip>           调度节点 IP (默认: ${NODE})
  --timeout <seconds>   超时时间 (默认: ${TIMEOUT})
  --sleep <seconds>     完成后休眠时间 (默认: ${SLEEP_TIME})
  --completions <n>     Job 执行次数 (默认: ${COMPLETIONS})
  --parallelism <n>     并行度 (默认: ${PARALLELISM})
  --output <path>       输出文件路径 (默认: dist/<job-name>.yml)
  --list                列出所有可用任务类型
  --help                显示帮助

示例:
  # 生成 UT 补充任务
  ./build.sh --task ut-gen --job-name xdm-f-core-ut \\
    --repo "git clone http://xdm:pass@host/xdm/xdm-f-core.git"

  # 生成重构任务，指定输出路径
  ./build.sh --task refactor --job-name xdm-refactor \\
    --repo "git clone http://xdm:pass@host/xdm/xdm-f-core.git" \\
    --output dist/xdm-refactor.yml
EOF
    exit 0
}

list_tasks() {
    echo "可用任务类型:"
    for task in "${AVAILABLE_TASKS[@]}"; do
        desc=""
        case "$task" in
            ut-gen)         desc="单元测试补充 — JUnit5+Mockito 为 Java 方法补充 UT" ;;
            feature-dev)    desc="功能开发 — 根据 plan.md 开发新功能" ;;
            refactor)       desc="代码重构 — 改善代码结构，不改变行为" ;;
            perf-optimize)  desc="性能优化 — 定位瓶颈，实施优化" ;;
            bug-fix)        desc="Bug 修复 — 从 issues.md 修复 Bug" ;;
        esac
        printf "  %-16s %s\n" "$task" "$desc"
    done
    exit 0
}

# ── 参数解析 ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)         TASK="$2"; shift 2 ;;
        --job-name)     JOB_NAME="$2"; shift 2 ;;
        --repo)         REPO_CLONE_CMD="$2"; shift 2 ;;
        --model)        MODEL="$2"; shift 2 ;;
        --base-url)     OPENAI_BASE_URL="$2"; shift 2 ;;
        --api-key)      OPENAI_API_KEY="$2"; shift 2 ;;
        --image)        IMAGE="$2"; shift 2 ;;
        --node)         NODE="$2"; shift 2 ;;
        --timeout)      TIMEOUT="$2"; shift 2 ;;
        --sleep)        SLEEP_TIME="$2"; shift 2 ;;
        --completions)  COMPLETIONS="$2"; shift 2 ;;
        --parallelism)  PARALLELISM="$2"; shift 2 ;;
        --output)       OUTPUT="$2"; shift 2 ;;
        --list)         list_tasks ;;
        --help|-h)      usage ;;
        *)              echo "未知参数: $1"; usage ;;
    esac
done

# ── 参数校验 ──────────────────────────────────────────────────────
if [[ -z "$TASK" ]]; then
    echo "❌ 错误: 必须指定 --task 参数"
    echo "使用 --list 查看所有可用任务类型"
    exit 1
fi

if [[ -z "$JOB_NAME" ]]; then
    echo "❌ 错误: 必须指定 --job-name 参数"
    exit 1
fi

if [[ -z "$REPO_CLONE_CMD" ]]; then
    echo "❌ 错误: 必须指定 --repo 参数"
    exit 1
fi

# 校验任务类型
TASK_FILE="${_PROMPTS_DIR}/task-${TASK}.md"
if [[ ! -f "$TASK_FILE" ]]; then
    echo "❌ 错误: 未知的任务类型 '${TASK}'"
    echo "可用类型: ${AVAILABLE_TASKS[*]}"
    exit 1
fi

# 校验模板文件
if [[ ! -f "$_TEMPLATE" ]]; then
    echo "❌ 错误: 模板文件不存在: $_TEMPLATE"
    exit 1
fi

# 默认输出路径
if [[ -z "$OUTPUT" ]]; then
    OUTPUT="${_SCRIPT_DIR}/dist/${JOB_NAME}.yml"
fi

# ── 合并 Prompt ──────────────────────────────────────────────────
echo "🔧 合并 Prompt..."
echo "   任务类型: ${TASK}"
echo "   Job 名称: ${JOB_NAME}"

MERGED_PROMPT=""

# 1. 基础模块
for base_file in base-system.md base-observability.md base-documentation.md; do
    BASE_PATH="${_PROMPTS_DIR}/${base_file}"
    if [[ -f "$BASE_PATH" ]]; then
        MERGED_PROMPT+="$(cat "$BASE_PATH")"
        MERGED_PROMPT+=$'\n\n---\n\n'
        echo "   ✓ ${base_file}"
    else
        echo "   ⚠ ${base_file} 不存在，跳过"
    fi
done

# 2. 任务特定模块
MERGED_PROMPT+="$(cat "$TASK_FILE")"
echo "   ✓ task-${TASK}.md"

# 3. 添加仓库克隆指令前缀
REPO_PROMPT="代码仓库为: \`${REPO_CLONE_CMD}\`;
必须使用HTTP方式克隆仓库, 禁止使用SSH方式克隆仓库, 如果重试10次仍然克隆仓库失败, 则结束本次任务;
执行代码仓库prompt.md文件中的指令;
鼓励使用sudo提权执行高权限操作例如安装软件;"

FULL_PROMPT="${REPO_PROMPT}

${MERGED_PROMPT}"

# ── 生成 YAML ────────────────────────────────────────────────────
echo ""
echo "📦 生成 YAML..."

mkdir -p "$(dirname "$OUTPUT")"

# 1. 将 prompt 写入临时文件（每行前加 16 个空格的缩进）
_TMP_PROMPT="$(mktemp)"
trap "rm -f '$_TMP_PROMPT'" EXIT
while IFS= read -r line; do
    printf '                %s\n' "$line"
done <<< "$FULL_PROMPT" > "$_TMP_PROMPT"

# 2. 读取模板，替换简单占位符，写入输出文件
sed \
    -e "s|__JOB_NAME__|${JOB_NAME}|g" \
    -e "s|__MODEL__|${MODEL}|g" \
    -e "s|__OPENAI_BASE_URL__|${OPENAI_BASE_URL}|g" \
    -e "s|__OPENAI_API_KEY__|${OPENAI_API_KEY}|g" \
    -e "s|__IMAGE__|${IMAGE}|g" \
    -e "s|__NODE__|${NODE}|g" \
    -e "s|__TIMEOUT__|${TIMEOUT}|g" \
    -e "s|__SLEEP_TIME__|${SLEEP_TIME}|g" \
    -e "s|__COMPLETIONS__|${COMPLETIONS}|g" \
    -e "s|__PARALLELISM__|${PARALLELISM}|g" \
    "$_TEMPLATE" > "$OUTPUT"

# 3. 将缩进后的 prompt 插入到 __PROMPT_CONTENT__ 占位行的位置
#    macOS sed 的 -i 需要备份后缀，用空串 '' 表示原地修改
#    使用 r 命令读取文件内容插入到匹配行之后，然后 d 删除占位行
sed -i '' -e "/__PROMPT_CONTENT__/{
    r ${_TMP_PROMPT}
    d
}" "$OUTPUT"

# ── 输出统计 ──────────────────────────────────────────────────────
PROMPT_LINES=$(echo "$FULL_PROMPT" | wc -l | tr -d ' ')
PROMPT_BYTES=$(echo "$FULL_PROMPT" | wc -c | tr -d ' ')
YAML_LINES=$(wc -l < "$OUTPUT" | tr -d ' ')

echo ""
echo "✅ 生成完成!"
echo "   输出文件: ${OUTPUT}"
echo "   Prompt: ${PROMPT_LINES} 行, ${PROMPT_BYTES} 字节"
echo "   YAML: ${YAML_LINES} 行"
echo ""
echo "📋 部署命令:"
echo "   kubectl apply -f ${OUTPUT}"
echo ""
echo "🗑️  清理命令:"
echo "   kubectl delete job ${JOB_NAME} -n ai"
echo "   kubectl delete configmap ${JOB_NAME}-file -n ai"
