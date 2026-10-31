"""Sessões Claude Code e Codex do PC, no mesmo formato que o Mac dá ao iPhone (Jarvis.Session / Message)."""
import json, os, glob, time, datetime, subprocess, shutil, threading
_CONSOLE_LOCK = threading.Lock()

HOME = os.path.expanduser("~")

def _tail(path, n):
    with open(path, "rb") as f:
        f.seek(0, 2); size = f.tell(); f.seek(max(0, size - n))
        return f.read().decode("utf-8", "ignore").splitlines()

def _ms(iso):
    try: return int(datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception: return int(time.time() * 1000)

def _alive(pid):
    """Processo vivo? (OpenProcess: sem tasklist, que abria uma janela preta a cada chamada com a app sem consola)."""
    import ctypes
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, int(pid or 0))  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h: return False
    code = ctypes.c_ulong(); k.GetExitCodeProcess(h, ctypes.byref(code)); k.CloseHandle(h)
    return code.value == 259  # STILL_ACTIVE

def claude_transcript(sid):
    for p in glob.glob(os.path.join(HOME, ".claude", "projects", "*", sid + ".jsonl")): return p

def claude_messages(sid, limit=60):
    p = claude_transcript(sid)
    if not p: return []
    out = []
    for l in _tail(p, 768 << 10):
        try: j = json.loads(l)
        except Exception: continue
        t = j.get("type")
        if t not in ("user", "assistant") or j.get("isSidechain") or j.get("isMeta"): continue
        m = j.get("message") or {}; c = m.get("content")
        at = _ms(j.get("timestamp", ""))
        if isinstance(c, str): text = c
        else:
            text = "\n".join(x.get("text", "") for x in (c or []) if isinstance(x, dict) and x.get("type") == "text")
            if t == "user": _shots(j, c, at, out)
            if t == "assistant":
                for i, x in enumerate(c or []):
                    if isinstance(x, dict) and x.get("type") == "tool_use":
                        inp = x.get("input") or {}
                        desc = isinstance(inp.get("description"), str) and "command" in inp  # Bash do Claude: frase humana
                        arg = inp["description"] if desc else next((inp[k] for k in ("command", "file_path", "pattern", "description", "url", "prompt") if isinstance(inp.get(k), str)), "")
                        img = x.get("name") == "Read" and arg.rsplit(".", 1)[-1].lower() in IMG
                        if inp.get("file_path"): arg = arg.replace("\\", "/") if img else os.path.basename(arg)  # imagem: caminho todo (o iPhone mostra-a)
                        out.append({"id": f"{j.get('uuid','')}-t{i}", "role": "tool", "text": f"{'Desc' if desc else x.get('name','Ferramenta')} · {arg[:160]}", "at": at})
        text = text.strip()
        if not text or (t == "user" and (text.startswith("<") or text.startswith("Caveat:"))): continue
        out.append({"id": j.get("uuid", ""), "role": "user" if t == "user" else "agent", "text": text, "at": at})
    return out[-limit:]

def claude_title(sid):
    p = claude_transcript(sid)
    if not p: return None
    custom = ai = None
    for l in _tail(p, 2 << 20):
        if '-title"' not in l: continue
        try: j = json.loads(l)
        except Exception: continue
        custom = j.get("customTitle") or custom; ai = j.get("aiTitle") or ai
    return custom or ai

def claude_sessions():
    out = []
    for f in glob.glob(os.path.join(HOME, ".claude", "sessions", "*.json")):
        try: j = json.load(open(f, encoding="utf-8"))
        except Exception: continue
        if j.get("kind", "interactive") != "interactive" or not _alive(j.get("pid", 0)): continue
        sid = j["sessionId"]; cwd = j.get("cwd", "")
        msgs = claude_messages(sid, 8); last = next((m for m in reversed(msgs) if m["role"] == "agent"), None)
        out.append({"id": sid, "kind": "claude", "name": claude_title(sid) or j.get("name") or os.path.basename(cwd),
                    "cwd": cwd, "status": j.get("status", "idle"), "updatedAt": j.get("updatedAt", 0), "pid": j.get("pid"),
                    "lastReply": last["text"][:160] if last else None, "canSend": True,
                    "tool": msgs[-1]["text"] if msgs and msgs[-1]["role"] == "tool" else None})
    return out

def _rollouts(max_age=12 * 3600):
    now = time.time(); out = []
    for back in (0, 1):
        d = datetime.date.today() - datetime.timedelta(days=back)
        for p in glob.glob(os.path.join(HOME, ".codex", "sessions", f"{d:%Y}", f"{d:%m}", f"{d:%d}", "*.jsonl")):
            if now - os.path.getmtime(p) < max_age: out.append(p)
    return out

def codex_parse(p, limit=60):
    out, busy = [], False
    for l in _tail(p, 1 << 20):
        try: j = json.loads(l)
        except Exception: continue
        pl = j.get("payload") or {}; pt = pl.get("type"); t = j.get("type")
        if t == "event_msg" and pt == "task_started": busy = True
        if t == "event_msg" and pt in ("task_complete", "turn_aborted"): busy = False
        if t == "response_item" and pt in ("function_call", "custom_tool_call"):  # ferramenta do Codex
            try: a = json.loads(pl.get("arguments") or "{}")
            except Exception: a = {}
            cmd = a.get("cmd") or (a.get("command") or [""])[-1] if isinstance(a, dict) else ""
            out.append({"id": pl.get("call_id", ""), "role": "tool", "text": pl.get("name", "") + (f" · {cmd}" if cmd else ""), "at": _ms(j.get("timestamp", ""))}); continue
        if t != "response_item" or pt != "message" or pl.get("role") not in ("user", "assistant"): continue
        text = "\n".join(x.get("text", "") for x in pl.get("content") or [] if isinstance(x, dict)).strip()
        if not text or (pl["role"] == "user" and text.startswith("<")): continue
        out.append({"id": pl.get("id", ""), "role": "user" if pl["role"] == "user" else "agent", "text": text, "at": _ms(j.get("timestamp", ""))})
    return out[-limit:], busy

def codex_names():
    names = {}
    f = os.path.join(HOME, ".codex", "session_index.jsonl")
    if os.path.exists(f):
        for l in _tail(f, 256 << 10):
            try: j = json.loads(l); names[j["id"]] = j["thread_name"]
            except Exception: pass
    return names

def codex_threads():
    names, out = codex_names(), []
    for p in _rollouts():
        try: meta = json.loads(open(p, encoding="utf-8").readline())
        except Exception: continue
        pl = meta.get("payload") or {}; tid = pl.get("id")
        if not tid or pl.get("thread_source", "user") != "user": continue
        msgs, busy = codex_parse(p, 6); mod = os.path.getmtime(p)
        last = next((m for m in reversed(msgs) if m["role"] == "agent"), None)
        cwd = pl.get("cwd", "")
        out.append({"id": tid, "kind": "codex", "name": names.get(tid) or os.path.basename(cwd) or "Codex", "cwd": cwd,
                    "status": "busy" if busy and time.time() - mod < 600 else "idle", "updatedAt": int(mod * 1000), "pid": None,
                    "lastReply": last["text"][:160] if last else None, "canSend": True,
                    "tool": msgs[-1]["text"] if msgs and msgs[-1]["role"] == "tool" else None})
    return out

def list_all():  # as conversas do próprio Jarvis (Fala\Jarvis) não entram
    return sorted((s for s in claude_sessions() + codex_threads() if not s["cwd"].replace("\\", "/").endswith("Fala/Jarvis")), key=lambda s: -s["updatedAt"])

def messages(sid, limit=60):
    p = next((p for p in _rollouts(7 * 86400) if sid and os.path.basename(p).endswith(sid + ".jsonl")), None)
    return codex_parse(p, limit)[0] if p else claude_messages(sid, limit)

def _clean(t): return "".join(ch for ch in t.replace("\n", " ") if ch.isprintable())

def send(sid, text):
    text = _clean(text)
    if not sid: return "Sessão inválida."
    if any(os.path.basename(p).endswith(sid + ".jsonl") for p in _rollouts(7 * 86400)):
        # Sem codex.cmd: o cmd.exe interpretaria & | < > ^ % no texto (injeção de comandos). Chama o node com o codex.js.
        js = os.path.join(HOME, "AppData", "Roaming", "npm", "node_modules", "@openai", "codex", "bin", "codex.js")
        node = shutil.which("node")
        if not (node and os.path.exists(js)): return "Codex não encontrado no PC."
        r = subprocess.run([node, js, "queue", "--thread", sid, "--message", text], capture_output=True, text=True, timeout=30, shell=False, creationflags=0x08000000)
        return None if r.returncode == 0 else ("codex queue falhou: " + (r.stderr or r.stdout)[-160:])
    for j in _claude_live():
        if j.get("sessionId") == sid: return type_into_console(j["pid"], text)
    return "Sessão não encontrada no PC."

def type_into_console(pid, text):
    """Escreve na consola DESSE processo (WriteConsoleInput), sem tocar no teclado nem noutras janelas."""
    # O Enter vai à parte: colado com o texto, o TUI do Claude trata-o como parte de um "paste" e não envia.
    return _console_keys(pid, [[(ch, 0, 0) for ch in text.replace("\n", " ")], [("\r", 0x0D, 0)]])

def _console_keys(pid, batches):
    """batches = listas de (char, vk, estado); 0,4 s entre listas."""
    import ctypes
    from ctypes import wintypes
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    class KEY(ctypes.Structure):
        _fields_ = [("bKeyDown", wintypes.BOOL), ("wRepeatCount", wintypes.WORD), ("wVirtualKeyCode", wintypes.WORD),
                    ("wVirtualScanCode", wintypes.WORD), ("UnicodeChar", wintypes.WCHAR), ("dwControlKeyState", wintypes.DWORD)]
    class REC(ctypes.Structure):
        _fields_ = [("EventType", wintypes.WORD), ("_pad", wintypes.WORD), ("Event", KEY)]
    with _CONSOLE_LOCK:
        k.FreeConsole()
        if not k.AttachConsole(pid): return f"Não consegui ligar à consola da sessão (erro {ctypes.get_last_error()})."
        try:
            h = k.CreateFileW("CONIN$", 0xC0000000, 3, None, 3, 0, None)
            if h in (0, -1): return "Sem acesso à consola da sessão."
            ok = True
            for bi, keys in enumerate(batches):
                if bi: time.sleep(0.4)
                recs = (REC * (len(keys) * 2))()
                for i, (ch, vk, st) in enumerate(keys):
                    for d in (0, 1):
                        r = recs[i * 2 + d]; r.EventType = 1; r.Event.bKeyDown = d == 0; r.Event.wRepeatCount = 1
                        r.Event.wVirtualKeyCode = vk; r.Event.UnicodeChar = ch; r.Event.dwControlKeyState = st
                n = wintypes.DWORD()
                ok = ok and k.WriteConsoleInputW(h, recs, len(recs), ctypes.byref(n))
            k.CloseHandle(h)
            return None if ok else f"Falhou a escrever na sessão (erro {ctypes.get_last_error()})."
        finally:
            k.FreeConsole()

def claude_mode(sid):
    """Modo de permissões atual (o último permissionMode do transcript) e se o bypass está disponível."""
    p = claude_transcript(sid)
    if not p: return "default", False
    tail = "\n".join(_tail(p, 256 << 10))
    parts = tail.split('"permissionMode":"')
    return (parts[-1].split('"')[0] if len(parts) > 1 else "default"), "bypassPermissions" in tail

def set_mode(sid, target):
    """Muda o modo com Shift+Tab na consola da sessão (o Claude não tem comando para isto)."""
    pid = next((j.get("pid") for j in _claude_live() if j.get("sessionId") == sid), None)
    if not pid: return "Sessão não encontrada no PC."
    cur, bypass = claude_mode(sid)
    cycle = ["default", "acceptEdits", "plan"] + (["bypassPermissions"] if bypass or target == "bypassPermissions" else [])
    if cur not in cycle or target not in cycle: return "Modo desconhecido"
    n = (cycle.index(target) - cycle.index(cur)) % len(cycle)
    return _console_keys(pid, [[("\t", 0x09, 0x0010)]] * n) if n else None  # 0x0010 = SHIFT_PRESSED

def _claude_live():
    for f in glob.glob(os.path.join(HOME, ".claude", "sessions", "*.json")):
        try: j = json.load(open(f, encoding="utf-8"))
        except Exception: continue
        if _alive(j.get("pid", 0)): yield j

IMG = ("png", "jpg", "jpeg", "gif", "webp", "heic")
SHOTS = os.path.join(HOME, "Pictures", "Fala", "shots")

def _shots(j, c, at, out):
    """Capturas que o agente viu (browser, ecrã): vêm em base64 no resultado da ferramenta. Guarda-as para o iPhone."""
    import base64
    for i, r in enumerate(c or []):
        if not (isinstance(r, dict) and r.get("type") == "tool_result" and isinstance(r.get("content"), list)): continue
        for k, x in enumerate(r["content"]):
            src = (x.get("source") or {}) if isinstance(x, dict) and x.get("type") == "image" else None
            if not src or not isinstance(src.get("data"), str): continue
            f = os.path.join(SHOTS, f"{j.get('uuid', 'x')}-{i}-{k}.{'png' if 'png' in src.get('media_type', '') else 'jpg'}")
            if not os.path.exists(f):
                try:
                    os.makedirs(SHOTS, exist_ok=True)
                    with open(f, "wb") as o: o.write(base64.b64decode(src["data"]))
                except Exception: continue
            prev = out[-1]["text"] if out else ""
            if prev.startswith("Read · ") and prev.rsplit(".", 1)[-1].lower() in IMG: continue  # a mesma foto que acabou de abrir
            out.append({"id": os.path.basename(f), "role": "tool", "text": "Image · " + f.replace("\\", "/"), "at": at})

def media(path):
    """Bytes de uma imagem/vídeo dentro das pastas permitidas (até 25 MB), ou None."""
    real = os.path.realpath(path or "")
    roots = [os.path.join(HOME, d) for d in ("Downloads", "Desktop", "Developer", os.path.join("Pictures", "Fala"))] + [os.environ.get("TEMP", "")]
    ok = any(r and os.path.normcase(real).startswith(os.path.normcase(os.path.realpath(r)) + os.sep) for r in roots)
    if not ok or real.rsplit(".", 1)[-1].lower() not in IMG + ("mp4", "mov") or not os.path.isfile(real) or os.path.getsize(real) >= 25 << 20: return None
    with open(real, "rb") as f: return f.read()
