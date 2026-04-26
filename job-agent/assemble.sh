#!/usr/bin/env bash
# assemble.sh — 单一组装入口（all-in-one YAML）
#
# 用法:
#   bash job-agent/assemble.sh job-agent/tasks/<name>/job.yml
#   bash job-agent/assemble.sh job-agent/tasks/<name>/job.yml -o my-output.yml
#   bash job-agent/assemble.sh job-agent/tasks/<name>/job.yml --apply
#
# 工作流:
#   1. 读取 job.yml 头部 `# assemble:` 注释提取文件映射 / skills / settings.json
#   2. 读取仓库根 config/centers.yaml，把镜像、LiteLLM、namespace 等中心配置注入 job spec
#   3. 拼接 ConfigMap（run.sh + prompt.md + settings.json）+ Skills ConfigMap + Job
#   4. 输出单一 YAML 到 dist/，可直接 kubectl apply
#
# # assemble: 注释支持的键:
#   run.sh=components/run.sh
#   prompt.md=tasks/<name>/prompt.md             单文件
#   prompt.md=prompts/base-system.md+tasks/<name>/prompt.md   '+' 拼接多文件
#   settings.json=components/settings.json
#   skills=components/skills                     整个目录
#   skills=components/skills/repo-guard,components/skills/ut-writer

set -euo pipefail

JOB_FILE="${1:?用法: bash assemble.sh <task-job.yml> [-o output.yml] [--apply]}"
shift

OUTPUT_FILE=""
DO_APPLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
        --apply) DO_APPLY=true; shift ;;
        *) echo "[ERROR] 未知参数: $1"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_DIR="$(cd "$(dirname "${JOB_FILE}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

[ -f "${JOB_FILE}" ] || { echo "[ERROR] Job 文件不存在: ${JOB_FILE}"; exit 1; }

python3 - "${JOB_FILE}" "${SCRIPT_DIR}" "${TASK_DIR}" "${REPO_ROOT}" "${OUTPUT_FILE}" "${DO_APPLY}" <<'PYTHON_SCRIPT'
import sys, os, yaml, subprocess, tempfile, json
from pathlib import Path
from datetime import datetime

job_file = sys.argv[1]
job_agent_dir = Path(sys.argv[2])
task_dir = Path(sys.argv[3])
repo_root = Path(sys.argv[4])
output_file = sys.argv[5] if sys.argv[5] else ""
do_apply = sys.argv[6] == "true"

# ── 0. 加载 centers.yaml（中心配置）────────────────────────────────
centers_path = repo_root / "config" / "centers.yaml"
centers = {}
if centers_path.exists():
    centers = yaml.safe_load(centers_path.read_text()) or {}
    print(f"[INFO] Loaded centers config: {centers_path}")
else:
    print(f"[WARN] {centers_path} 不存在，跳过中心配置注入")

def resolve_path(val):
    return Path(val) if os.path.isabs(val) else job_agent_dir / val

# ── 1. 提取 assemble 映射 ──────────────────────────────────────────
file_map = {}        # key → str | List[str]（List 表示多文件拼接）
skills_dirs = []
settings_file = ""

with open(job_file) as f:
    for line in f:
        line = line.strip()
        if not line.startswith("# assemble:"):
            continue
        part = line.split("# assemble:")[1].strip()
        if "=" not in part:
            continue
        key, val = part.split("=", 1)
        key, val = key.strip(), val.strip()

        if key == "skills":
            for s in val.split(","):
                s = s.strip()
                p = resolve_path(s)
                if p.is_dir():
                    skills_dirs.append(p)
                else:
                    print(f"[WARN] Skills path not found: {p}", file=sys.stderr)
        elif key == "settings.json":
            p = resolve_path(val)
            settings_file = str(p) if p.exists() else ""
        else:
            # 支持 `+` 拼接多文件 → key 写入 ConfigMap 时合并
            if "+" in val:
                parts = [str(resolve_path(s.strip())) for s in val.split("+")]
                file_map[key] = parts
            else:
                file_map[key] = str(resolve_path(val))

# 默认映射
if "run.sh" not in file_map:
    file_map["run.sh"] = str(job_agent_dir / "components" / "run.sh")
if "prompt.md" not in file_map:
    pp = task_dir / "prompt.md"
    if pp.exists():
        file_map["prompt.md"] = str(pp)
if not settings_file:
    sf = job_agent_dir / "components" / "settings.json"
    if sf.exists():
        settings_file = str(sf)

if not skills_dirs:
    default_skills = job_agent_dir / "components" / "skills"
    if default_skills.is_dir() and any(default_skills.iterdir()):
        skills_dirs.append(default_skills)

# ── 2. 收集 Skills ─────────────────────────────────────────────────
skills_data = {}
for skills_dir in skills_dirs:
    skill_md_direct = skills_dir / "SKILL.md"
    if skill_md_direct.exists():
        skills_data[skills_dir.name] = skill_md_direct.read_text()
    else:
        for skill_dir in sorted(skills_dir.iterdir()):
            if not skill_dir.is_dir():
                continue
            skill_md = skill_dir / "SKILL.md"
            if skill_md.exists():
                skills_data[skill_dir.name] = skill_md.read_text()

# ── 3. 解析 Job YAML ──────────────────────────────────────────────
with open(job_file) as f:
    docs = list(yaml.safe_load_all(f))

job_doc = None
for doc in docs:
    if doc and doc.get("kind") == "Job":
        job_doc = doc
        break

if not job_doc:
    print("[ERROR] 没有找到 kind: Job 定义", file=sys.stderr)
    sys.exit(1)

job_name = job_doc.get("metadata", {}).get("name", "unnamed-job")
namespace = job_doc.get("metadata", {}).get("namespace") \
    or centers.get("kubernetes", {}).get("namespace", "default")
job_doc.setdefault("metadata", {})["namespace"] = namespace

configmap_name = f"{job_name}-config"
for vol in job_doc.get("spec", {}).get("template", {}).get("spec", {}).get("volumes", []):
    cm = vol.get("configMap", {})
    if cm.get("name"):
        configmap_name = cm["name"]
        break

skills_cm_name = f"{job_name}-skills"

# ── 4. 注入 centers.yaml 的中心配置 ────────────────────────────────
spec = job_doc["spec"]["template"]["spec"]
containers = spec.get("containers", [])

# nodeName（如 centers.kubernetes.node 已配置且 spec 中未指定）
node = centers.get("kubernetes", {}).get("node")
if node and "nodeName" not in spec:
    spec["nodeName"] = node

if containers:
    c = containers[0]
    # image 默认值（按 stack）
    if c.get("image", "").endswith(":__from_centers__") or not c.get("image"):
        stack = c.get("image", "").split(":")[0] or "general"
        img = centers.get("image", {}).get(stack)
        if img:
            c["image"] = img
            print(f"[INFO] 镜像注入: {stack} → {img}")

    # 环境变量补全：ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY 来自 centers.litellm
    env_list = c.setdefault("env", [])
    existing_env_names = {e.get("name") for e in env_list}
    litellm = centers.get("litellm", {})
    if litellm.get("base_url") and "ANTHROPIC_BASE_URL" not in existing_env_names:
        env_list.append({"name": "ANTHROPIC_BASE_URL", "value": litellm["base_url"]})
    if (
        litellm.get("secret_name")
        and litellm.get("secret_key")
        and "ANTHROPIC_API_KEY" not in existing_env_names
    ):
        env_list.append({
            "name": "ANTHROPIC_API_KEY",
            "valueFrom": {"secretKeyRef": {
                "name": litellm["secret_name"],
                "key": litellm["secret_key"],
            }},
        })
    if litellm.get("default_model") and "ANTHROPIC_MODEL" not in existing_env_names:
        env_list.append({"name": "ANTHROPIC_MODEL", "value": litellm["default_model"]})

# ── 5. 注入 Skills / settings.json 卷 ──────────────────────────────
if skills_data or settings_file:
    volumes = spec.get("volumes", [])

    if containers:
        c = containers[0]
        mounts = c.get("volumeMounts", [])
        if skills_data and not any(m.get("name") == "skills" for m in mounts):
            mounts.append({"name": "skills", "mountPath": "/skills", "readOnly": True})
        if settings_file and not any(m.get("name") == "settings" for m in mounts):
            mounts.append({
                "name": "settings",
                "subPath": "settings.json",
                "mountPath": "/home/pipeline/.claude/settings.json",
                "readOnly": True,
            })
        c["volumeMounts"] = mounts

    if skills_data:
        sources = []
        for skill_name in sorted(skills_data):
            sources.append({"configMap": {
                "name": skills_cm_name,
                "items": [{"key": f"{skill_name}-SKILL.md",
                           "path": f"{skill_name}/SKILL.md"}],
            }})
        if not any(v.get("name") == "skills" for v in volumes):
            volumes.append({"name": "skills", "projected": {"sources": sources}})

    if settings_file and not any(v.get("name") == "settings" for v in volumes):
        volumes.append({"name": "settings", "configMap": {
            "name": configmap_name,
            "items": [{"key": "settings.json", "path": "settings.json"}],
        }})

    spec["volumes"] = volumes

# ── 6. 输出路径 ────────────────────────────────────────────────────
if not output_file:
    dist_dir = job_agent_dir / "dist"
    dist_dir.mkdir(exist_ok=True)
    output_file = str(dist_dir / f"{job_name}.yml")

# ── 7. 验证文件存在 ────────────────────────────────────────────────
print(f"[INFO] Assembling: {job_file}")
print(f"[INFO] ConfigMap:  {configmap_name} (ns: {namespace})")
print(f"[INFO] Files:")
for key in sorted(file_map):
    src = file_map[key]
    if isinstance(src, list):
        print(f"  - {key} ← (concat) {len(src)} files")
        for s in src:
            if not os.path.isfile(s):
                print(f"      ❌ {s} (NOT FOUND)", file=sys.stderr)
                sys.exit(1)
            print(f"      + {s}")
    else:
        if not os.path.isfile(src):
            print(f"  ❌ {key} ← {src} (NOT FOUND)", file=sys.stderr)
            sys.exit(1)
        print(f"  - {key} ← {src}")

if settings_file:
    print(f"  - settings.json ← {settings_file}")
if skills_data:
    print(f"[INFO] Skills ({len(skills_data)}):")
    for s in sorted(skills_data):
        print(f"  - {s}")

# ── 8. 生成合并后的 YAML ──────────────────────────────────────────
def write_concat(out, src_list):
    for i, s in enumerate(src_list):
        if i > 0:
            out.write("\n\n")
        with open(s) as sf:
            for line in sf:
                out.write(line.rstrip() + "\n")

with open(output_file, "w") as out:
    out.write(f"# Auto-generated by assemble.sh — {datetime.now():%Y-%m-%d %H:%M:%S}\n")
    out.write(f"# Source: {job_file}\n")
    out.write(f"# DO NOT EDIT — 请修改源文件后重新运行 assemble.sh\n#\n")
    out.write(f"# 用法:\n")
    out.write(f"#   kubectl apply -f {output_file}\n")
    out.write(f"#   kubectl -n {namespace} logs -f -l job-name={job_name}\n")
    out.write(f"#   kubectl delete -f {output_file}\n\n")

    # === ConfigMap: run.sh + prompt.md + settings.json ===
    out.write("---\n")
    out.write("kind: ConfigMap\napiVersion: v1\nmetadata:\n")
    out.write(f"  name: {configmap_name}\n  namespace: {namespace}\ndata:\n")

    for key in sorted(file_map):
        src = file_map[key]
        out.write(f'  "{key}": |-\n')
        if isinstance(src, list):
            tmp_buf = []
            for i, s in enumerate(src):
                if i > 0:
                    tmp_buf.append("")
                    tmp_buf.append("")
                with open(s) as sf:
                    for line in sf:
                        tmp_buf.append(line.rstrip())
            for line in tmp_buf:
                out.write(f"    {line}\n")
        else:
            with open(src) as sf:
                for line in sf:
                    out.write(f"    {line.rstrip()}\n")

    if settings_file:
        out.write(f'  "settings.json": |-\n')
        with open(settings_file) as sf:
            for line in sf:
                out.write(f"    {line.rstrip()}\n")

    # === ConfigMap: Skills ===
    if skills_data:
        out.write("\n---\nkind: ConfigMap\napiVersion: v1\nmetadata:\n")
        out.write(f"  name: {skills_cm_name}\n  namespace: {namespace}\ndata:\n")
        for skill_name in sorted(skills_data):
            content = skills_data[skill_name]
            out.write(f'  "{skill_name}-SKILL.md": |-\n')
            for line in content.splitlines():
                out.write(f"    {line}\n")

    # === Job ===
    out.write("\n---\n")
    yaml.dump(job_doc, out, default_flow_style=False, allow_unicode=True, sort_keys=False)

# ── 9. 验证 ────────────────────────────────────────────────────────
print(f"\n[INFO] Output: {output_file}")
print(f"[INFO] Size:   {os.path.getsize(output_file)} bytes")
print("[INFO] Validating...")

with open(output_file) as f:
    out_docs = list(yaml.safe_load_all(f))
for i, doc in enumerate(out_docs):
    if doc:
        print(f"  doc[{i}]: {doc.get('kind','?')}/{doc.get('metadata',{}).get('name','?')}")
print("  ✅ YAML syntax OK")

for doc in out_docs:
    if doc and doc.get("kind") == "ConfigMap":
        for key, val in doc.get("data", {}).items():
            if key.endswith(".sh"):
                with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as tmp:
                    tmp.write(val); tmp.flush()
                    r = subprocess.run(["bash", "-n", tmp.name], capture_output=True, text=True)
                    os.unlink(tmp.name)
                    print(f"  {'✅' if r.returncode == 0 else '❌'} {key}: bash syntax {'OK' if r.returncode == 0 else r.stderr}")
            elif key.endswith(".json"):
                try:
                    json.loads(val); print(f"  ✅ {key}: JSON syntax OK")
                except json.JSONDecodeError as e:
                    print(f"  ❌ {key}: {e}")

if skills_data:
    print(f"  ✅ {len(skills_data)} skills embedded")

print(f"\n[OK] Assembly complete: {output_file}")

if do_apply:
    print("\n[INFO] Applying to cluster...")
    subprocess.run(["kubectl", "apply", "-f", output_file], check=True)
PYTHON_SCRIPT
