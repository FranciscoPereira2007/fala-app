"""Contas de IA deste PC: Claude (Claude Code) e ChatGPT (Codex). Estado, entrar e instalar.
Entrar abre o browser do PC (o login é sempre da própria pessoa, nunca passa pela Fala); do iPhone faz-se o mesmo
pelo ecrã remoto. Usado pela janela (fala_app.py) e por GET/POST /accounts (server.py)."""
import json, os, shutil, subprocess, threading, time

NEW_CONSOLE, NO_WINDOW = 0x00000010, 0x08000000
HOME = os.path.expanduser("~")
EXTRA = [os.path.join(HOME, ".local", "bin"), os.path.join(os.environ.get("APPDATA", ""), "npm")]  # onde os instaladores os põem

def _which(n):
    return shutil.which(n) or shutil.which(n, path=os.pathsep.join(EXTRA))

def _run(args, t=15):
    try: return subprocess.run(args, capture_output=True, text=True, timeout=t, creationflags=NO_WINDOW)
    except Exception: return None

_cache = {"at": 0.0, "v": None}
_lock = threading.Lock()

def status() -> dict:
    """Estado em cache (os CLIs demoram 2 a 5 s): responde já e refresca em fundo a cada 30 s."""
    with _lock:
        fresh = time.time() - _cache["at"] < 30
        if _cache["v"] is not None and fresh: return _cache["v"]
        if _cache["v"] is not None:
            _cache["at"] = time.time(); threading.Thread(target=_refresh, daemon=True).start(); return _cache["v"]
    return _refresh()

_one = threading.Lock()  # dois "claude auth status" ao mesmo tempo às vezes dão "não ligado"

def _refresh() -> dict:
    with _one: v = _status()
    with _lock: _cache.update(at=time.time(), v=v)
    return v

def _status() -> dict:
    out = {}
    c = _which("claude")
    r = _run([c, "auth", "status", "--json"], 30) if c else None
    try: logged = bool(json.loads(r.stdout[r.stdout.index("{"):]).get("loggedIn")) if r else False  # pode vir texto antes do JSON
    except Exception: logged = False
    out["claude"] = {"installed": bool(c), "loggedIn": logged, "name": "Claude"}
    x = _which("codex")
    r = _run([x, "login", "status"], 30) if x else None
    out["codex"] = {"installed": bool(x), "loggedIn": bool(r and r.returncode == 0 and "logged in" in (r.stdout + r.stderr).lower()), "name": "ChatGPT"}
    return out

def login(which: str) -> str:
    """Abre o login no browser deste PC. Devolve o que fazer a seguir (pt)."""
    exe = _which("claude" if which == "claude" else "codex")
    if not exe: return install(which)
    args = [exe, "auth", "login"] if which == "claude" else [exe, "login"]
    subprocess.Popen(args, creationflags=NEW_CONSOLE)
    _cache["at"] = 0  # o próximo pedido volta a ver o estado
    return "Abri o login no browser do PC. Acaba lá (no iPhone: Ver e mexer no PC)."

def install(which: str) -> str:
    """Instala com o instalador oficial numa janela visível (a pessoa vê o que corre)."""
    if which == "claude":
        cmd = "irm https://claude.ai/install.ps1 | iex; claude auth login"
    else:
        cmd = ("if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements; "
               "$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User') }; "
               "npm install -g @openai/codex; codex login")
    subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-Command", cmd], creationflags=NEW_CONSOLE)
    return "A instalar numa janela do PC; no fim abre o login no browser."

if __name__ == "__main__":
    print(json.dumps(status(), indent=1))
