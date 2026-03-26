import sys, json

TEXT_LIMIT    = 500
CONTENT_LINES = 15

# Colors for terminal output
C_THOUGHT = '\033[38;5;245m'  # Dim gray for thoughts
C_ACTION  = '\033[1;36m'      # Cyan for actions
C_RESULT  = '\033[0;32m'      # Green for results
C_INFO    = '\033[1;34m'      # Blue for info
C_RESET   = '\033[0m'
C_DIM     = '\033[2m'         # Dim filter for results

def p(s, end='\n'):
    print(s, end=end, flush=True)

def process(obj):
    t = obj.get('type', '')

    if t == 'system' and obj.get('subtype') == 'init':
        p(f"\n{C_INFO}🚀 [Init] model={obj.get('model','')} cwd={obj.get('cwd','')}{C_RESET}")
        return

    if t == 'assistant':
        content = obj.get('message', {}).get('content', [])
        has_thought = False
        for block in content:
            bt = block.get('type', '')
            if bt == 'text':
                text = block.get('text', '').strip()
                if not text: continue
                if len(text) > TEXT_LIMIT: text = text[:TEXT_LIMIT] + ' ... (truncated)'
                if not has_thought:
                    p(f"\n{C_THOUGHT}🧠 [Thought]{C_RESET}")
                    has_thought = True
                for ln in text.splitlines():
                    if ln.strip(): p(f"{C_THOUGHT}    {ln}{C_RESET}")
            elif bt == 'tool_use':
                name = block.get('name', '')
                inp  = block.get('input', {})
                p(f"{C_ACTION}🛠️  [{name}]{C_RESET} ", end="")
                if name == 'Bash':
                    cmd = inp.get('command', '').replace('\n', '; ')[:120]
                    p(f"$ {cmd}")
                elif name == 'Read':
                    fp = inp.get('file_path', '')
                    rng = f" L{inp.get('offset', '')}+{inp.get('limit', '')}" if inp.get('offset') else ""
                    p(f"📄 {fp}{rng}")
                elif name == 'Write' or name == 'Edit':
                    p(f"📝 {inp.get('file_path', '')}")
                elif name == 'Glob':
                    p(f"🔍 {inp.get('pattern', '')}")
                elif name == 'Grep':
                    p(f"🔎 {inp.get('pattern', '')} @ {inp.get('path', '.')}")
                elif name in ('TodoWrite', 'TodoRead'):
                    p(f"📋 {len(inp.get('todos', []))} tasks")
                else:
                    p(f"▶ {str(inp)[:80]}")
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
            if str(tr.get('exitCode', '0')) != '0' and stderr:
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
        color = '\033[0;31m' if is_err else C_RESULT

        if not has_content and not parts:
            p(f"{color}    {icon} [Success]{C_RESET}")
            return

        p(f"{color}    {icon} [Result]{C_RESET}")

        if isinstance(tr, dict):
            if stdout:
                lines = stdout.rstrip().splitlines()
                for ln in lines[:CONTENT_LINES]:
                    p(f"{C_DIM}      | {ln.strip()[:150]}{C_RESET}")
                if len(lines) > CONTENT_LINES:
                    p(f"{C_DIM}      | ... ({len(lines) - CONTENT_LINES} more lines){C_RESET}")
            if stderr and is_err:
                for ln in stderr.rstrip().splitlines()[:10]:
                    p(f"{C_DIM}      ! {ln.strip()[:150]}{C_RESET}")
            if content and not stdout:
                if isinstance(content, list):
                    lines = [str(item)[:150] for item in content]
                elif isinstance(content, str):
                    lines = content.splitlines()
                else:
                    lines = [str(content)]
                for ln in lines[:CONTENT_LINES]:
                    p(f"{C_DIM}      | {ln.strip()[:150]}{C_RESET}")
                if len(lines) > CONTENT_LINES:
                    p(f"{C_DIM}      | ... ({len(lines) - CONTENT_LINES} more lines){C_RESET}")
            if parts:
                p(f"{C_DIM}      └─ {', '.join(parts)}{C_RESET}")
        elif isinstance(tr, list):
            for item in tr[:3]:
                p(f"{C_DIM}      | {str(item)[:120]}{C_RESET}")
        else:
            text = str(tr).strip()
            if text:
                for ln in text.splitlines()[:5]:
                    p(f"{C_DIM}      | {ln.strip()[:150]}{C_RESET}")
        return

    if 'content' in obj or 'tool_use_result' in obj:
        file_obj = obj.get('file') or {}
        content  = obj.get('content', '')
        if isinstance(content, str) and content.strip():
            lines = content.splitlines()
            for ln in lines[:CONTENT_LINES]:
                p(f"{C_DIM}      | {ln.strip()[:150]}{C_RESET}")
            if len(lines) > CONTENT_LINES:
                p(f"{C_DIM}      | ... ({len(lines) - CONTENT_LINES} more lines){C_RESET}")
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
