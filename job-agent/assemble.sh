#!/usr/bin/env bash
# assemble.sh - 将 components + task 合并为 all-in-one YAML
#
# 用法:
#   bash job-agent/assemble.sh job-agent/tasks/xdm-ut/job.yml
#   bash job-agent/assemble.sh job-agent/tasks/xdm-ut/job.yml -o my-output.yml
#   bash job-agent/assemble.sh job-agent/tasks/xdm-ut/job.yml --apply
#
# 工作原理:
#   1. 读取 job.yml 头部的 # assemble: 注释提取文件映射
#   2. 从 job.yml 中解析 ConfigMap 和 Job 元数据
#   3. 将 run.sh + prompt.md 嵌入 ConfigMap
#   4. 如果有 skills 指令，生成 Skills ConfigMap + 对应的 volume 挂载
#   5. 输出完整 YAML 到 dist/
#
# 文件映射格式（写在 job.yml 头部注释中）:
#   # assemble: run.sh=components/run.sh
#   # assemble: prompt.md=tasks/xdm-ut/prompt.md
#   # assemble: settings.json=components/settings.json
#   # assemble: skills=components/skills          ← 整个目录
#   # assemble: skills=components/skills/ut-planner,components/skills/ut-writer  ← 逗号分隔

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

[ -f "${JOB_FILE}" ] || { echo "[ERROR] Job 文件不存在: ${JOB_FILE}"; exit 1; }

python3 - "${JOB_FILE}" "${SCRIPT_DIR}" "${TASK_DIR}" "${OUTPUT_FILE}" "${DO_APPLY}" <<'PYTHON_SCRIPT'
import sys, os, yaml, subprocess, tempfile, json
from pathlib import Path
from datetime import datetime

job_file = sys.argv[1]
job_agent_dir = Path(sys.argv[2])
task_dir = Path(sys.argv[3])
output_file = sys.argv[4] if sys.argv[4] else ""
do_apply = sys.argv[5] == "true"

# ── 1. 提取 assemble 映射 ──────────────────────────────────────────
file_map = {}       # key → file_path (for single files)
skills_dirs = []    # list of skill directories
settings_file = ""  # settings.json path

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
            # skills 可以是目录或逗号分隔的多个目录
            for s in val.split(","):
                s = s.strip()
                p = Path(s) if os.path.isabs(s) else job_agent_dir / s
                if p.is_dir():
                    skills_dirs.append(p)
                else:
                    print(f"[WARN] Skills path not found: {p}", file=sys.stderr)
        elif key == "settings.json":
            p = Path(val) if os.path.isabs(val) else job_agent_dir / val
            settings_file = str(p) if p.exists() else ""
        else:
            p = Path(val) if os.path.isabs(val) else job_agent_dir / val
            file_map[key] = str(p)

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

# 如果没指定 skills，检查 components/skills 目录是否存在
if not skills_dirs:
    default_skills = job_agent_dir / "components" / "skills"
    if default_skills.is_dir() and any(default_skills.iterdir()):
        skills_dirs.append(default_skills)

# ── 2. 收集 Skills ─────────────────────────────────────────────────
# skills_data: {skill_name: content}
skills_data = {}
for skills_dir in skills_dirs:
    skill_md_direct = skills_dir / "SKILL.md"
    if skill_md_direct.exists():
        # 指向的是单个 skill 目录 (如 components/skills/repo-guard)
        skills_data[skills_dir.name] = skill_md_direct.read_text()
    else:
        # 指向的是父目录 (如 components/skills)，遍历子目录
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
namespace = job_doc.get("metadata", {}).get("namespace", "default")

# ConfigMap 名
configmap_name = f"{job_name}-config"
for vol in job_doc.get("spec", {}).get("template", {}).get("spec", {}).get("volumes", []):
    cm = vol.get("configMap", {})
    if cm.get("name"):
        configmap_name = cm["name"]
        break

skills_cm_name = f"{job_name}-skills"

# ── 4. 注入 Skills 挂载到 Job spec ─────────────────────────────────
if skills_data or settings_file:
    spec = job_doc["spec"]["template"]["spec"]
    containers = spec.get("containers", [])
    volumes = spec.get("volumes", [])

    if containers:
        c = containers[0]
        mounts = c.get("volumeMounts", [])

        # Skills volume mount
        if skills_data:
            # 挂载到 /skills, run.sh 负责同步到 .claude/skills
            if not any(m.get("name") == "skills" for m in mounts):
                mounts.append({
                    "name": "skills",
                    "mountPath": "/skills",
                    "readOnly": True,
                })

        # Settings.json mount
        if settings_file:
            if not any(m.get("name") == "settings" for m in mounts):
                mounts.append({
                    "name": "settings",
                    "subPath": "settings.json",
                    "mountPath": "/home/pipeline/.claude/settings.json",
                    "readOnly": True,
                })

        c["volumeMounts"] = mounts

    # Skills volume 定义 (projected volume)
    if skills_data:
        # 用 projected volume 把所有 skill 挂到 /skills/<skill-name>/SKILL.md
        sources = []
        for skill_name in sorted(skills_data):
            sources.append({
                "configMap": {
                    "name": skills_cm_name,
                    "items": [{
                        "key": f"{skill_name}-SKILL.md",
                        "path": f"{skill_name}/SKILL.md",
                    }],
                }
            })
        if not any(v.get("name") == "skills" for v in volumes):
            volumes.append({
                "name": "skills",
                "projected": {"sources": sources},
            })

    # Settings volume
    if settings_file:
        if not any(v.get("name") == "settings" for v in volumes):
            volumes.append({
                "name": "settings",
                "configMap": {
                    "name": configmap_name,
                    "items": [{"key": "settings.json", "path": "settings.json"}],
                },
            })

    spec["volumes"] = volumes

# ── 5. 输出路径 ────────────────────────────────────────────────────
if not output_file:
    dist_dir = job_agent_dir / "dist"
    dist_dir.mkdir(exist_ok=True)
    output_file = str(dist_dir / f"{job_name}.yml")

# ── 6. 验证文件存在 ────────────────────────────────────────────────
print(f"[INFO] Assembling: {job_file}")
print(f"[INFO] ConfigMap:  {configmap_name} (ns: {namespace})")
print(f"[INFO] Files:")
for key in sorted(file_map):
    src = file_map[key]
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

# ── 7. 生成合并后的 YAML ──────────────────────────────────────────
with open(output_file, "w") as out:
    # 头部注释
    out.write(f"# Auto-generated by assemble.sh — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    out.write(f"# Source: {job_file}\n")
    out.write(f"# DO NOT EDIT — 请修改源文件后重新运行 assemble.sh\n")
    out.write(f"#\n")
    out.write(f"# 用法:\n")
    out.write(f"#   kubectl apply -f {output_file}\n")
    out.write(f"#   kubectl -n {namespace} logs -f -l job-name={job_name}\n")
    out.write(f"#   kubectl delete -f {output_file}\n")
    out.write(f"\n")

    # === ConfigMap: run.sh + prompt.md + settings.json ===
    out.write("---\n")
    out.write("kind: ConfigMap\n")
    out.write("apiVersion: v1\n")
    out.write("metadata:\n")
    out.write(f"  name: {configmap_name}\n")
    out.write(f"  namespace: {namespace}\n")
    out.write("data:\n")

    for key in sorted(file_map):
        src = file_map[key]
        out.write(f'  "{key}": |-\n')
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
        out.write(f"\n---\n")
        out.write("kind: ConfigMap\n")
        out.write("apiVersion: v1\n")
        out.write("metadata:\n")
        out.write(f"  name: {skills_cm_name}\n")
        out.write(f"  namespace: {namespace}\n")
        out.write("data:\n")
        for skill_name in sorted(skills_data):
            content = skills_data[skill_name]
            out.write(f'  "{skill_name}-SKILL.md": |-\n')
            for line in content.splitlines():
                out.write(f"    {line}\n")

    # === Job ===
    out.write("\n---\n")
    yaml.dump(job_doc, out, default_flow_style=False, allow_unicode=True, sort_keys=False)

# ── 8. 验证 ────────────────────────────────────────────────────────
print(f"\n[INFO] Output: {output_file}")
print(f"[INFO] Size:   {os.path.getsize(output_file)} bytes")
print(f"\n[INFO] Validating...")

with open(output_file) as f:
    out_docs = list(yaml.safe_load_all(f))
for i, doc in enumerate(out_docs):
    if doc:
        kind = doc.get("kind", "?")
        name = doc.get("metadata", {}).get("name", "?")
        print(f"  doc[{i}]: {kind}/{name}")
print("  ✅ YAML syntax OK")

for doc in out_docs:
    if doc and doc.get("kind") == "ConfigMap":
        data = doc.get("data", {})
        for key, val in data.items():
            if key.endswith(".sh"):
                with tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False) as tmp:
                    tmp.write(val)
                    tmp.flush()
                    r = subprocess.run(["bash", "-n", tmp.name], capture_output=True, text=True)
                    os.unlink(tmp.name)
                    status = "✅" if r.returncode == 0 else "❌"
                    print(f"  {status} {key}: bash syntax {'OK' if r.returncode == 0 else r.stderr}")
            elif key.endswith(".json"):
                try:
                    json.loads(val)
                    print(f"  ✅ {key}: JSON syntax OK")
                except json.JSONDecodeError as e:
                    print(f"  ❌ {key}: {e}")

if skills_data:
    print(f"  ✅ {len(skills_data)} skills embedded")

print(f"\n[OK] Assembly complete: {output_file}")

if do_apply:
    print("\n[INFO] Applying to cluster...")
    subprocess.run(["kubectl", "apply", "-f", output_file], check=True)
PYTHON_SCRIPT
