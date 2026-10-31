"""O teu Jarvis (como o Dot do ChatGPT): um agente sempre disponível neste computador, numa pasta só dele
(~/Fala/Jarvis) com memória em ficheiros. Corre com a conta da própria pessoa: Codex (ChatGPT, também no plano
grátis) ou Claude Code. Cada pedido continua a mesma conversa (resume pelo id guardado).
Usado por POST /jarvis {"text"} (server.py) a partir do iPhone: chat e chamada por voz."""
import json, os, subprocess, tempfile, threading
import accounts, time, uuid

HOME = os.path.join(os.path.expanduser("~"), "Fala", "Jarvis")
STATE = os.path.join(HOME, ".fala-jarvis.json")
NO_WINDOW = 0x08000000
_lock = threading.Lock()  # um pedido de cada vez: é uma só conversa

GUIDE = """# Jarvis

És o Jarvis da Fala: o assistente pessoal de {name}, neste computador (Windows). Como o Dot do ChatGPT:
um agente sempre disponível que faz o trabalho no computador e manda nas outras sessões de IA.

- Falas português de Portugal, direto e curto. As respostas são lidas em voz alta: no máximo 3 frases,
  sem listas, sem código, sem URLs, sem travessões. Se fizeste trabalho, diz o resultado e o próximo passo.
- A tua pasta é esta. Guarda o que aprendes sobre {name} em memoria.md (preferências, nomes, projetos)
  e lê-a no início de cada pedido. Coisas que fazes muitas vezes ficam em skills/<nome>.md.
- Pede confirmação antes de apagar, pagar, enviar mensagens ou emails em nome de {name}.
- Estás numa conversa por voz: se o pedido dá trabalho, a tua PRIMEIRA mensagem é uma frase curta a dizer o que
  vais fazer ("Vou ver os teus emails."), antes de usares ferramentas. Ela é dita logo em voz alta.

## As outras sessões (Claude Code e Codex deste PC)

{name} pode dizer "diz à sessão da loja para...", "o que está a fazer o Codex do site?" ou "cria uma sessão
nova para...". Usa a API local da Fala (PowerShell). A URL e o token estão em .fala-api (1.ª e 2.ª linha):

    $a = Get-Content .fala-api; $h = @{{"X-Fala-Token" = $a[1]}}
    Invoke-RestMethod "$($a[0])/sessions" -Headers $h            # lista: id, kind, name, cwd, status, lastReply
    Invoke-RestMethod "$($a[0])/tail?id=<id>&limit=20" -Headers $h  # últimas mensagens
    Invoke-RestMethod "$($a[0])/send" -Method Post -Headers $h -ContentType "application/json" -Body (@{{id="<id>"; text="..."}} | ConvertTo-Json)
    Invoke-RestMethod "$($a[0])/new" -Method Post -Headers $h -ContentType "application/json" -Body (@{{cwd="C:\\caminho"; prompt="..."}} | ConvertTo-Json)

Ignora as sessões cuja pasta é Fala\\Jarvis: são as tuas próprias conversas.
Escolher a sessão certa (pensa, não adivinhes):
1. Lista as sessões e, para CADA uma ativa, lê o tail (limit=8): o que a pessoa lhe pediu e em que está a trabalhar.
2. Compara com o pedido: o projeto/app de que ele fala ("a Fala", "a loja"), o assunto (voz, chamada, ecrã),
   ficheiros e pastas. A sessão certa é a que já está a trabalhar NESSE projeto, mesmo que o nome não o diga.
3. Nunca mandes para a sessão de outro projeto só por estar ativa ou ser a mais recente.
4. Duas igualmente boas, ou nenhuma? Pergunta qual (diz os nomes e o que cada uma está a fazer).
Depois de mandar, espera um pouco e lê o tail para lhe dizeres o que a sessão respondeu.
"""

DEFAULTS = {"engine": "auto", "model": "", "access": "computador"}  # access: "computador" (tudo) ou "pasta" (só a dele)

def ensure_home():
    os.makedirs(HOME, exist_ok=True)
    guide = GUIDE.format(name=_person())
    for f in ("AGENTS.md", "CLAUDE.md"):  # são nossos (a memória da pessoa vive em memoria.md): atualizam-se
        p = os.path.join(HOME, f)
        if not os.path.exists(p) or open(p, encoding="utf-8").read() != guide: open(p, "w", encoding="utf-8").write(guide)
    import config
    open(os.path.join(HOME, ".fala-api"), "w").write(f"http://127.0.0.1:{config.PORT}\n{config.token()}\n")
    m = os.path.join(HOME, "memoria.md")
    if not os.path.exists(m): open(m, "w", encoding="utf-8").write("# Memória\n")

def _person():
    return os.environ.get("USERNAME", "").split(".")[0].title() or "a pessoa"

def _state():
    try: return json.load(open(STATE))
    except Exception: return {}

def settings() -> dict:
    return {**DEFAULTS, **{k: v for k, v in _state().items() if k in DEFAULTS}}

def config_get() -> dict:
    """Para o iPhone: definições atuais e os modelos que cada conta tem."""
    exe = accounts._which("codex")
    codex = []
    if exe:
        try:
            r = _run([exe, "debug", "models"], 30); d = json.loads(r.stdout); ms = d.get("models", d) if isinstance(d, dict) else d
            codex = [m.get("slug") for m in ms if isinstance(m, dict) and m.get("visibility") == "list"]
        except Exception: pass
    st = accounts.status()
    return {**settings(), "models": {"codex": codex, "claude": ["sonnet", "opus", "haiku"]},
            "accounts": {k: v["loggedIn"] for k, v in st.items()}}

def config_set(c: dict) -> dict:
    st = _state()
    for k in DEFAULTS:
        if k in c: st[k] = str(c[k])
    if "model" in c: st.pop("codex", None); st.pop("claude", None)  # modelo novo: conversa nova
    json.dump(st, open(STATE, "w")); return settings()

def new_session(cwd: str, prompt: str) -> dict:
    """Sessão nova (Codex) numa pasta: corre em fundo e aparece na lista de sessões."""
    exe = accounts._which("codex")
    if not exe: return {"ok": False, "error": "Codex não instalado"}
    cwd = cwd if cwd and os.path.isdir(cwd) else HOME
    full = settings()["access"] == "computador"
    args = [exe, "exec", "--skip-git-repo-check", "-c", f'sandbox_mode="{"danger-full-access" if full else "workspace-write"}"']
    if _model.get("ok"): args += ["-m", _model["ok"]]
    subprocess.Popen(args + [prompt], cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=NO_WINDOW)
    return {"ok": True}

def engine():
    """Escolhida pela pessoa, ou: Claude (Sonnet, esforço médio) se a conta estiver ligada, senão Codex."""
    want = settings()["engine"]
    st = accounts.status()
    if want in ("codex", "claude") and st[want]["loggedIn"]: return want
    if st["claude"]["loggedIn"]: return "claude"  # auto: Claude primeiro (percebe melhor a que sessão te referes)
    if st["codex"]["loggedIn"]: return "codex"
    return None

def ask(text: str, timeout=300) -> dict:
    """Envia o pedido ao Jarvis e espera pela resposta final. {"ok", "reply" | "error", "engine"}."""
    text = (text or "").strip()
    if not text: return {"ok": False, "error": "Pedido vazio"}
    eng = engine()
    if not eng: return {"ok": False, "error": "Liga a tua conta do ChatGPT ou do Claude neste computador (Contas de IA)."}
    with _lock:
        ensure_home()
        st = _state(); sid = st.get(eng)
        try:
            chosen = settings()["model"]
            if eng == "codex":
                m = chosen or _model.get("ok") or st.get("codexModel")
                reply, sid = _codex(text, sid, timeout, m)
                if not chosen and _model.get("ok"): st["codexModel"] = _model["ok"]
            else:
                reply, sid = _claude(text, sid, timeout, chosen if chosen in ("sonnet", "opus", "haiku") else None)
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": "O Jarvis ainda está a trabalhar nisso. Pergunta-lhe daqui a pouco.", "engine": eng}
        except Exception as e:
            return {"ok": False, "error": f"O Jarvis falhou: {e}", "engine": eng}
        if sid: st[eng] = sid; json.dump(st, open(STATE, "w"))
    return {"ok": bool(reply), "reply": reply, "error": None if reply else "Sem resposta", "engine": eng}

def _codex_home():
    """O Codex do Jarvis tem casa própria (só com o login da pessoa): sem as skills e MCPs dela arranca muito mais depressa."""
    import shutil
    h = os.path.join(HOME, ".codex"); os.makedirs(h, exist_ok=True)
    src = os.path.join(os.path.expanduser("~"), ".codex", "auth.json")
    if os.path.exists(src): shutil.copyfile(src, os.path.join(h, "auth.json"))
    return h

def _run(args, timeout, on_line=None):
    """Como subprocess.run, mas no fim do tempo mata a árvore toda (cmd -> node -> codex.exe), não só o cmd."""
    env = {**os.environ, "CODEX_HOME": _codex_home()} if "codex" in os.path.basename(args[0]).lower() else None
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, cwd=HOME, env=env,
                         text=True, encoding="utf-8", errors="ignore", creationflags=NO_WINDOW)
    killed = []
    def kill(): killed.append(1); subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], capture_output=True, creationflags=NO_WINDOW)
    t = threading.Timer(timeout, kill); t.start()
    lines = []
    for line in p.stdout:  # linha a linha: o iPhone vai dizendo o que o Jarvis já disse enquanto trabalha
        lines.append(line)
        if on_line: on_line(line)
    p.wait(); t.cancel()
    if killed: raise subprocess.TimeoutExpired(args, timeout)
    return subprocess.CompletedProcess(args, p.returncode, "".join(lines), "")

_model = {"m": None}

def _codex_model(exe):
    """Primeiro modelo que a conta da pessoa mostra (o config.toml dela pode pedir um que a conta ChatGPT não aceita)."""
    if _model["m"] is None:
        try:
            r = subprocess.run([exe, "debug", "models"], capture_output=True, text=True, encoding="utf-8", errors="ignore", timeout=30,
                               stdin=subprocess.DEVNULL, creationflags=NO_WINDOW)
            d = json.loads(r.stdout); ms = d.get("models", d) if isinstance(d, dict) else d
            _model["m"] = next((m.get("slug") for m in ms if isinstance(m, dict) and m.get("visibility") == "list"), "") or ""
        except Exception: _model["m"] = ""
    return _model["m"]

def _codex(text, sid, timeout, model=None):
    exe = accounts._which("codex")
    out = os.path.join(tempfile.gettempdir(), "fala-jarvis-last.txt")
    if os.path.exists(out): os.remove(out)
    # sandbox por -c (o "resume" não aceita -C/-s; a pasta vem do cwd)
    mode = "danger-full-access" if settings()["access"] == "computador" else "workspace-write"
    opts = ["--json", "--skip-git-repo-check", "-c", f'sandbox_mode="{mode}"', "-c", 'model_reasoning_effort="low"', "-o", out]  # "max" do config.toml = 14 s para um olá + (["-m", model] if model else [])
    args = [exe, "exec", "resume", sid] + opts + [text] if sid else [exe, "exec"] + opts + [text]
    def on_line(l):  # {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
        if "agent_message" not in l: return
        try: j = json.loads(l)
        except Exception: return
        if j.get("type") == "item.completed" and (j.get("item") or {}).get("type") == "agent_message" and _current.get("id") in _jobs:
            _jobs[_current["id"]].setdefault("progress", []).append(j["item"].get("text", ""))
    r = _run(args, timeout, on_line)
    new, failed = sid, ""
    for line in r.stdout.splitlines():  # {"type":"thread.started","thread_id":"..."} / {"type":"turn.failed",...}
        try: j = json.loads(line)
        except Exception: continue
        new = j.get("thread_id") or j.get("session_id") or new
        if j.get("type") == "turn.failed": failed = json.dumps(j)
    try: reply = open(out, encoding="utf-8").read().strip()
    except Exception: reply = ""
    if not reply and "not supported" in failed and not model and _codex_model(exe):  # modelo do config.toml recusado pela conta
        _model["ok"] = _codex_model(exe)
        return _codex(text, sid, timeout, _codex_model(exe))
    if not reply and sid:  # conversa antiga apagada: começa outra
        return _codex(text, None, timeout, model)
    return reply, new

def _claude(text, sid, timeout, model=None):
    exe = accounts._which("claude")
    perm = "bypassPermissions" if settings()["access"] == "computador" else "acceptEdits"
    args = [exe, "-p", text, "--output-format", "json", "--permission-mode", perm] + (["--resume", sid] if sid else []) + ["--model", model or "sonnet", "--effort", "max" if model == "haiku" else "medium", "--setting-sources", "project,local"]  # sem os hooks globais: metade do tempo
    r = _run(args, timeout)
    try: j = json.loads(r.stdout[r.stdout.index("{"):])
    except Exception: j = {}
    if not j.get("result") and sid: return _claude(text, None, timeout, model)
    return (j.get("result") or "").strip(), j.get("session_id") or sid

# Pedidos em fundo: o relay corta aos 55 s e o Jarvis pode trabalhar minutos. POST devolve um id; GET vai buscar.
_jobs: dict = {}
_current: dict = {}  # o pedido em curso (um de cada vez, pelo _lock)

def start(text: str) -> str:
    jid = uuid.uuid4().hex[:12]
    _jobs[jid] = {"done": False, "at": time.time(), "progress": []}
    def run():
        with _lock: pass  # espera a vez (ask volta a pegar no lock)
        _current["id"] = jid
        _jobs[jid] = {**_jobs[jid], **ask(text), "done": True, "at": time.time()}
    threading.Thread(target=run, daemon=True).start()
    for k in [k for k, v in _jobs.items() if time.time() - v["at"] > 3600]: _jobs.pop(k, None)
    return jid

def result(jid: str) -> dict:
    return _jobs.get(jid) or {"done": True, "ok": False, "error": "Pedido desconhecido"}

if __name__ == "__main__":
    import sys
    print(json.dumps(ask(" ".join(sys.argv[1:]) or "Diz olá numa frase."), ensure_ascii=False, indent=1))
