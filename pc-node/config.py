"""Onde a Fala para Windows guarda as coisas e o código deste PC (o mesmo formato do Mac: 26 símbolos, ~128 bits).
Instalação do Fran (pasta fala-node com code.txt ao lado): usa essa pasta. App instalada: %APPDATA%\\Fala."""
import base64, hashlib, hmac, os, secrets, socket, sys

HERE = os.path.dirname(os.path.abspath(__file__))
BUNDLE = getattr(sys, "_MEIPASS", HERE)  # PyInstaller: ffmpeg.exe e ícone vêm aqui
DATA = HERE if os.path.exists(os.path.join(HERE, "code.txt")) else os.path.join(os.environ.get("APPDATA", HERE), "Fala")
os.makedirs(DATA, exist_ok=True)
PORT = 47900
ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

def _path(n): return os.path.join(DATA, n)

def code(new=False) -> str:
    """Código de emparelhamento (chave da cifra e da sala do relay). new=True troca-o: iPhones antigos deixam de entrar."""
    if not new and os.path.exists(_path("code.txt")):
        c = open(_path("code.txt")).read().strip().upper()
        if len(c) >= 26: return c
    c = "".join(secrets.choice(ALPHABET) for _ in range(26))
    open(_path("code.txt"), "w").write(c)
    return c

def hkdf(salt: bytes, n=32, info=b"") -> bytes:
    prk = hmac.new(salt, code().encode(), hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:n]

def token() -> str:
    """Token só da rede de casa: HKDF(código, "fala-pc-v1"), igual ao PCNode.token do iPhone/Mac."""
    return base64.urlsafe_b64encode(hkdf(b"fala-pc-v1", 24)).decode()

def lan_ip() -> str:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(("8.8.8.8", 80)); ip = s.getsockname()[0]; s.close(); return ip
    except OSError: return ""

def name() -> str: return os.environ.get("COMPUTERNAME", "PC").title()

def pair_url() -> str:
    from urllib.parse import urlencode
    q = {"k": "pc", "t": code(), "n": name()}
    if lan_ip(): q["h"] = f"{lan_ip()}:{PORT}"
    return "fala://pair?" + urlencode(q)

def ffmpeg() -> str:
    for p in (os.path.join(BUNDLE, "ffmpeg.exe"), os.path.join(HERE, "ffmpeg.exe")):
        if os.path.exists(p): return p
    return "ffmpeg"

if __name__ == "__main__":  # verificação: o token bate com o do Swift (HKDF-SHA256 sem info, 24 bytes, base64url)
    import tempfile
    DATA = tempfile.mkdtemp()
    open(_path("code.txt"), "w").write("ABCDEFGHJKMNPQRSTUVWXYZ234")
    prk = hmac.new(b"fala-pc-v1", b"ABCDEFGHJKMNPQRSTUVWXYZ234", hashlib.sha256).digest()
    assert token() == base64.urlsafe_b64encode(hmac.new(prk, b"\x01", hashlib.sha256).digest()[:24]).decode()
    assert len(code(new=True)) == 26 and code() != "ABCDEFGHJKMNPQRSTUVWXYZ234"
    assert pair_url().startswith("fala://pair?k=pc&t=")
    print("ok")
