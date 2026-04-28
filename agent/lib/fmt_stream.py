import os
import re
import sys, json
from datetime import datetime, timezone, timedelta

TEXT_LIMIT = int(os.getenv("FMT_STREAM_TEXT_LIMIT", "0") or "0")
CONTENT_LINES = int(os.getenv("FMT_STREAM_CONTENT_LINES", "0") or "0")
LINE_LIMIT = int(os.getenv("FMT_STREAM_LINE_LIMIT", "0") or "0")

# Colors for terminal output
C_THOUGHT = '\033[38;5;245m'  # Dim gray for thoughts
C_ACTION  = '\033[1;36m'      # Cyan for actions
C_RESULT  = '\033[0;32m'      # Green for results
C_INFO    = '\033[1;34m'      # Blue for info
C_WARN    = '\033[38;5;214m'  # Orange for warnings
C_ERR     = '\033[0;31m'      # Red for errors
C_RESET   = '\033[0m'
C_DIM     = '\033[2m'         # Dim filter for results
C_MARK    = '\033[1;35m'      # Magenta for skills/subagents/parallel markers

def p(s, end='\n'):
    tz = timezone(timedelta(hours=8))
    ts = datetime.now(tz).strftime('%Y-%m-%d %H:%M:%S')
    if s.startswith('\n'):
        print(f"\n{C_DIM}[{ts}]{C_RESET} {s[1:]}", end=end, flush=True)
    else:
        print(f"{C_DIM}[{ts}]{C_RESET} {s}", end=end, flush=True)

def limited_text(text, limit=TEXT_LIMIT):
    if limit and len(text) > limit:
        return text[:limit] + f" ... (truncated by FMT_STREAM_TEXT_LIMIT={limit})"
    return text

def limited_line(line):
    if LINE_LIMIT and len(line) > LINE_LIMIT:
        return line[:LINE_LIMIT] + f" ... (line truncated by FMT_STREAM_LINE_LIMIT={LINE_LIMIT})"
    return line

def emit_lines(lines, color=C_DIM, prefix="      │ "):
    total = len(lines)
    shown = lines if not CONTENT_LINES else lines[:CONTENT_LINES]
    for ln in shown:
        p(f"{color}{prefix}{limited_line(str(ln).rstrip())}{C_RESET}")
    if CONTENT_LINES and total > CONTENT_LINES:
        p(f"{color}{prefix}... ({total - CONTENT_LINES} more lines; set FMT_STREAM_CONTENT_LINES=0 for full output){C_RESET}")

def skill_names_from_text(text):
    return sorted(set(re.findall(r"(?:^|\s)/skills?\s+([A-Za-z0-9_.-]+)", text)))

def tool_label(name, inp):
    lname = name.lower()
    if name == "Task" or "subagent" in lname or inp.get("subagent_type"):
        agent = inp.get("subagent_type") or inp.get("agent") or inp.get("name") or "default"
        desc = inp.get("description") or inp.get("prompt") or ""
        first_line = str(desc).splitlines()[0] if str(desc).splitlines() else ""
        return "subagent", f"🤖 [Subagent:{agent}] {limited_line(first_line)}"
    if "parallel" in lname:
        return "parallel", f"🔀 [Parallel Tool] {name}"
    if "skill" in lname:
        skill = inp.get("skill") or inp.get("name") or inp.get("skill_name") or ""
        return "skill", f"🧩 [Skill] {skill or name}"

    joined_input = " ".join(str(v) for v in inp.values() if isinstance(v, (str, int, float)))
    found_skills = skill_names_from_text(joined_input)
    if found_skills:
        return "skill", f"🧩 [Skill Call] {', '.join(found_skills)}"
    return "", ""

def process(obj):
    t = obj.get('type', '')

    if t == 'system' and obj.get('subtype') == 'init':
        p(f"\n{C_INFO}🚀 [Init] model={obj.get('model','')} cwd={obj.get('cwd','')}{C_RESET}")
        return

    if t == 'error':
        err_msg = obj.get('error', '')
        if isinstance(err_msg, dict):
            err_msg = err_msg.get('message', str(err_msg))
        p(f"\n{C_ERR}🚨 [System Error] {err_msg}{C_RESET}")
        return

    if t == 'user':
        content = obj.get('message', {}).get('content', [])
        text_blocks = []
        for block in content:
            if isinstance(block, dict) and block.get('type') == 'text':
                text_blocks.append(str(block.get('text', '')))
        text = "".join(text_blocks)
        if text:
            # 只取第一行的一部分作为提示
            lines = text.strip().split("\n")
            if lines:
                short_str = str(lines[0])[:80]
                p(f"\n{C_INFO}👤 [User Prompt] {short_str}...{C_RESET}")
        return

    if t == 'assistant':
        content = obj.get('message', {}).get('content', [])
        tool_blocks = [b for b in content if isinstance(b, dict) and b.get('type') == 'tool_use']
        if len(tool_blocks) > 1:
            names = ", ".join(str(b.get("name", "")) for b in tool_blocks)
            p(f"    {C_MARK}🔀 [Parallel] {len(tool_blocks)} tool calls in this assistant turn: {names}{C_RESET}")
        has_thought = False
        for block in content:
            if not isinstance(block, dict):
                continue
            bt = block.get('type', '')
            if bt == 'text':
                text = block.get('text', '').strip()
                if not text: continue
                skills = skill_names_from_text(text)
                if skills:
                    p(f"    {C_MARK}🧩 [Skill Mention] {', '.join(skills)}{C_RESET}")
                text = limited_text(text)
                if not has_thought:
                    p(f"\n{C_THOUGHT}🧠 [Thought]{C_RESET}")
                    has_thought = True
                for ln in text.splitlines():
                    if ln.strip(): p(f"{C_THOUGHT}    {ln}{C_RESET}")
            elif bt == 'tool_use':
                name = block.get('name', '')
                inp  = block.get('input', {})
                kind, marker = tool_label(name, inp if isinstance(inp, dict) else {})
                if marker:
                    p(f"    {C_MARK}{marker}{C_RESET}")
                    if kind in ("subagent", "parallel"):
                        continue
                if name == 'Bash':
                    cmd = limited_line(inp.get('command', '').replace('\n', '; '))
                    p(f"    {C_ACTION}⚡ [{name}]{C_RESET} $ {cmd}")
                elif name == 'Read':
                    fp = inp.get('file_path', '')
                    rng = f" L{inp.get('offset', '')}+{inp.get('limit', '')}" if inp.get('offset') else ""
                    p(f"    {C_ACTION}📄 [{name}]{C_RESET} {fp}{rng}")
                elif name in ('Write', 'Edit'):
                    p(f"    {C_ACTION}📝 [{name}]{C_RESET} {inp.get('file_path', '')}")
                elif name == 'Glob':
                    p(f"    {C_ACTION}🔍 [{name}]{C_RESET} {inp.get('pattern', '')}")
                elif name == 'Grep':
                    p(f"    {C_ACTION}🔎 [{name}]{C_RESET} {inp.get('pattern', '')} @ {inp.get('path', '.')}")
                elif name in ('TodoWrite', 'TodoRead'):
                    p(f"    {C_ACTION}📋 [{name}]{C_RESET} {len(inp.get('todos', []))} tasks")
                else:
                    p(f"    {C_ACTION}🛠️  [{name}]{C_RESET} {limited_line(str(inp))}")
        return

    tr = obj.get('tool_use_result') or (obj if t == 'tool_result' else None)
    if tr is not None:
        has_content = False
        parts = []
        is_err = False
        if isinstance(tr, dict):
            stdout = tr.get('stdout', '')
            stderr = tr.get('stderr', '')
            content = tr.get('content', '')
            
            # Better error checking
            if str(tr.get('exitCode', '0')) != '0' or tr.get('is_error'):
                is_err = True
                
            for k in ('numLines', 'totalLines', 'numFiles', 'exitCode'):
                if k in tr: parts.append(f"{k}={tr[k]}")
            if stdout or stderr or content:
                has_content = True
        elif isinstance(tr, list) and tr:
            has_content = True
        else:
            if str(tr).strip(): has_content = True

        icon = '❌' if is_err else '✅'
        color = C_ERR if is_err else C_RESULT
        title = '[Error]' if is_err else '[Result]'

        if not has_content and not parts:
            p(f"{color}    {icon} {title}{C_RESET}")
            return

        p(f"{color}    {icon} {title}{C_RESET}")

        if isinstance(tr, dict):
            if stdout:
                lines = stdout.rstrip().splitlines()
                emit_lines(lines, C_DIM)
            if stderr:
                err_color = C_ERR if is_err else C_WARN
                lines = stderr.rstrip().splitlines()
                emit_lines(lines, err_color)
            if content and not stdout:
                if isinstance(content, list):
                    lines = [str(item) for item in content]
                elif isinstance(content, str):
                    lines = content.splitlines()
                else:
                    lines = [str(content)]
                emit_lines(lines, C_DIM)
            if parts:
                p(f"{C_DIM}      ╰─ {', '.join(parts)}{C_RESET}")
        elif isinstance(tr, list):
            emit_lines([str(item) for item in tr], C_DIM)
        else:
            text = str(tr).strip()
            if text:
                emit_lines(text.splitlines(), C_DIM)
        return

    if 'content' in obj or 'tool_use_result' in obj:
        file_obj = obj.get('file') or {}
        content  = obj.get('content', '')
        if isinstance(content, str) and content.strip():
            lines = content.splitlines()
            emit_lines(lines, C_DIM)
        elif file_obj:
            fp  = file_obj.get('filePath', '')
            nln = file_obj.get('numLines', '?')
            p(f"{C_DIM}      < file: {fp}  ({nln} lines){C_RESET}")
        return

    if t == 'result':
        cost = obj.get('cost_usd', 0) or 0
        turns = obj.get('num_turns', 0)
        p(f"\n{C_INFO}🏁 [结束 DONE] turns={turns} cost=${cost:.4f}{C_RESET}")

for raw in sys.stdin:
    raw = raw.strip()
    if not raw: continue
    try:
        obj = json.loads(raw)
    except ValueError:
        continue
    try:
        process(obj)
    except Exception:
        pass
