"""Ecrã do PC ao vivo no iPhone, com o dedo como rato (o mesmo protocolo do ScreenStream do Mac).
Como o Parsec no Windows (visto com o REA no parsecd): Desktop Duplication (ddagrab, D3D11) -> codificador H.264 da GPU
-> TCP cifrado (CallFrame); rato e teclas voltam pela mesma ligação e entram por SendInput.
Corre dentro do server.py (porta 47900): uma ligação que começa por "F2" é o ecrã, o resto é HTTP."""
import ctypes, ctypes.wintypes as W, hashlib, hmac, json, os, struct, subprocess, threading, time
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

import config
CODE = config.code()
VIDEO, CTRL, HANGUP, UP, DOWN = 0x76, 0x63, 0x68, 0x55, 0x44

def hkdf(ikm: bytes, salt: bytes, info: bytes, n=32) -> bytes:
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:n]

LINK = hkdf(CODE.encode(), b"fala-link-v2", b"iphone-mac")  # LinkCrypto.key

def frame(box: bytes) -> bytes: return b"F2" + struct.pack(">I", len(box)) + box
def seal(key: ChaCha20Poly1305, plain: bytes) -> bytes:
    n = os.urandom(12); return frame(n + key.encrypt(n, plain, None))
def read_frame(sock, buf: bytearray):
    """Um frame "F2" completo (só a caixa nonce+cifra+tag), ou None se a ligação fechou."""
    while True:
        if len(buf) >= 6:
            if buf[:2] != b"F2": return None
            n = 6 + struct.unpack(">I", buf[2:6])[0]
            if len(buf) >= n:
                box = bytes(buf[6:n]); del buf[:n]; return box
        d = sock.recv(65536)
        if not d: return None
        buf += d

SEEN: dict[bytes, float] = {}  # anti-replay do aperto de mão (ids vistos nos últimos 4 min)

def serve(sock):
    """Ligação do iPhone: aperto de mão "V" e depois vídeo para lá, rato/teclas para cá."""
    sock.setsockopt(6, 1, 1)  # TCP_NODELAY
    buf = bytearray()
    box = read_frame(sock, buf)
    if not box: return
    try: p = ChaCha20Poly1305(LINK).decrypt(box[:12], box[12:], None)
    except Exception: return  # código errado
    rid, ms, body = p[:16], struct.unpack(">q", p[16:24])[0], p[24:]
    now = time.time()
    for k in [k for k, t in SEEN.items() if now - t > 240]: del SEEN[k]
    if abs(now - ms / 1000) > 120 or rid in SEEN or body[:1] != b"V": return
    SEEN[rid] = now
    nonce = os.urandom(16)
    sock.sendall(seal(ChaCha20Poly1305(LINK), rid + b"V" + nonce))
    key = ChaCha20Poly1305(hkdf(LINK, rid + nonce, b"fala-call-v1"))
    try: hello = json.loads(body[1:] or b"{}")
    except Exception: hello = {}
    if hello.get("r"): sock.setsockopt(0xFFFF, 0x1001, 32768)  # SO_SNDBUF pequeno pelo relay: o atraso não acumula
    Stream(sock, key, buf, remote=bool(hello.get("r"))).run()

class Stream:
    def __init__(self, sock, key, buf, remote=False):
        self.sock, self.key, self.buf, self.seq, self.ended, self.remote = sock, key, buf, 0, False, remote
        self.lock = threading.Lock()

    def send(self, kind, payload):
        with self.lock:
            self.seq += 1
            self.sock.sendall(seal(self.key, bytes([DOWN]) + struct.pack(">Q", self.seq) + bytes([kind]) + payload))

    def run(self):
        threading.Thread(target=self.controls, daemon=True).start()
        # ponytail: resolução nativa do monitor principal (o scale_d3d11 deste ffmpeg falha); h264_mf = GPU pelo Media Foundation,
        # porque o NVENC direto pede driver NVIDIA >= 570. Com driver novo: -c:v h264_nvenc -preset p1 -tune ull (menos atraso).
        # Fora de casa (pelo relay): 1600 px a 30 fps e 2 Mbps, como o perfil remoto do Mac; em casa, nativo a 60 fps.
        grab = ("ddagrab=output_idx=0:framerate=30:draw_mouse=1,hwdownload,format=bgra,scale='min(1600,iw)':-2,format=nv12" if self.remote
                else "ddagrab=output_idx=0:framerate=60:draw_mouse=1")
        cmd = [config.ffmpeg(), "-nostdin", "-hide_banner", "-loglevel", "error", "-init_hw_device", "d3d11va", "-filter_complex", grab,
               "-c:v", "h264_mf", "-hw_encoding", "1", "-scenario", "display_remoting", "-b:v", "2M" if self.remote else "10M",
               "-g", "90" if self.remote else "60", "-bf", "0",
               "-bsf:v", "h264_metadata=aud=insert", "-f", "h264", "-"]
        self.ff = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, creationflags=0x08000000)
        try:
            for au in access_units(self.ff.stdout):
                if self.ended: break
                self.send(VIDEO, au)
        except OSError: pass
        finally: self.end()

    def controls(self):
        last = 0
        try:
            while not self.ended:
                box = read_frame(self.sock, self.buf)
                if not box: break
                p = self.key.decrypt(box[:12], box[12:], None)
                seq = struct.unpack(">Q", p[1:9])[0]
                if p[0] != UP or seq <= last: break
                last = seq
                if p[9] == HANGUP: break
                if p[9] == CTRL:
                    try: apply(json.loads(p[10:]))
                    except Exception as e: print("ecrã: comando falhou", e, flush=True)
        except Exception: pass
        self.end()

    def end(self):
        if self.ended: return
        self.ended = True
        try: self.ff.kill()
        except Exception: pass
        try: self.sock.close()
        except Exception: pass

def nals(data: bytes):
    """NALUs de um bloco Annex B (sem os códigos de início)."""
    i, out = 0, []
    starts = []
    while True:
        j = data.find(b"\x00\x00\x01", i)
        if j < 0: break
        starts.append(j + 3); i = j + 3
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else len(data)
        n = data[s:e]
        while n.endswith(b"\x00"): n = n[:-1]  # zero do código de 4 bytes seguinte
        if n: out.append(n)
    return out

def access_units(pipe):
    """Frames prontos para o iPhone: [flags] (+ keyframe: [n] e n × [len u16][SPS/PPS]) + NALUs com 4 bytes de tamanho.
    O ffmpeg mete um AUD antes de cada frame; um frame acaba quando chega o AUD do seguinte."""
    pend = b""
    while True:
        d = pipe.read1(1 << 16) if hasattr(pipe, "read1") else pipe.read(1 << 16)
        if not d: return
        pend += d
        while True:
            a = pend.find(b"\x00\x00\x01\x09")
            b = pend.find(b"\x00\x00\x01\x09", a + 4) if a >= 0 else -1
            if b < 0: break
            au, pend = pend[a:b], pend[b:]
            sets, body, key = [], b"", False
            for n in nals(au):
                t = n[0] & 0x1F
                if t in (7, 8): sets.append(n)
                elif t in (1, 5):
                    key |= t == 5; body += struct.pack(">I", len(n)) + n
            if not body: continue
            head = bytes([1, len(sets)]) + b"".join(struct.pack(">H", len(s)) + s for s in sets) if key and sets else b"\x00"
            yield head + body

# MARK: rato e teclado (RemoteInput.Cmd do Mac, traduzido para Windows)

u32 = ctypes.windll.user32
try: u32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))  # píxeis reais: o 0..1 do iPhone bate certo com 125%/150%
except Exception: pass

class MI(ctypes.Structure): _fields_ = [("dx", W.LONG), ("dy", W.LONG), ("data", W.DWORD), ("flags", W.DWORD), ("time", W.DWORD), ("extra", ctypes.c_size_t)]
class KI(ctypes.Structure): _fields_ = [("vk", W.WORD), ("scan", W.WORD), ("flags", W.DWORD), ("time", W.DWORD), ("extra", ctypes.c_size_t)]
class _U(ctypes.Union): _fields_ = [("mi", MI), ("ki", KI), ("pad", ctypes.c_byte * 32)]
class INPUT(ctypes.Structure): _fields_ = [("type", W.DWORD), ("u", _U)]

def _send(*ins):
    arr = (INPUT * len(ins))(*ins); u32.SendInput(len(ins), arr, ctypes.sizeof(INPUT))
def mouse(flags, data=0): i = INPUT(0); i.u.mi = MI(0, 0, data & 0xFFFFFFFF, flags, 0, 0); return i
def key(vk=0, up=False, uni=None):
    i = INPUT(1)
    ext = 1 if vk in EXT else 0
    i.u.ki = KI(0, uni, 4 | (2 if up else 0), 0, 0) if uni is not None else KI(vk, 0, ext | (2 if up else 0), 0, 0)
    return i

VK = {"return": 0x0D, "tab": 0x09, "space": 0x20, "delete": 0x08, "escape": 0x1B, "forwarddelete": 0x2E,
      "left": 0x25, "up": 0x26, "right": 0x27, "down": 0x28, "home": 0x24, "end": 0x23, "pageup": 0x21, "pagedown": 0x22}
EXT = {0x25, 0x26, 0x27, 0x28, 0x24, 0x23, 0x21, 0x22, 0x2E, 0x5B}
CTRL_, SHIFT, ALT, WIN = 0x11, 0x10, 0x12, 0x5B
ARROWS = {"left", "right", "up", "down"}
dragging = False

def combo(vks, n=1):
    for _ in range(n):
        _send(*[key(v) for v in vks], *[key(v, up=True) for v in reversed(vks)])

def press(k, mods, n):
    """Tecla do Mac -> Windows: ⌘ = Ctrl; ⌥ nas setas/⌫ = Ctrl (salta palavras); ⌃+setas sozinho = gestos de 3 dedos."""
    k = k.lower(); mods = set(mods or [])
    if mods == {"ctrl"} and k in ARROWS:  # 3 dedos: lados = ambiente de trabalho virtual, cima = Vista de Tarefas, baixo = Ambiente de trabalho
        combo({"left": [WIN, CTRL_, 0x25], "right": [WIN, CTRL_, 0x27], "up": [WIN, 0x09], "down": [WIN, 0x44]}[k]); return
    if "cmd" in mods and k in ARROWS:  # ⌘← / ⌘→ = início/fim da linha; ⌘↑ / ⌘↓ = início/fim do texto
        vk = {"left": 0x24, "right": 0x23, "up": 0x24, "down": 0x23}[k]
        combo(([SHIFT] if "shift" in mods else []) + ([CTRL_] if k in ("up", "down") else []) + [vk], n); return
    if "cmd" in mods and k == "delete": combo([SHIFT, 0x24]); combo([0x08]); return  # apaga até ao início da linha
    vk = VK.get(k)
    if vk is None:
        if len(k) != 1: return
        r = u32.VkKeyScanW(ord(k))
        if r == -1: return
        vk = r & 0xFF
    word = "opt" in mods and k in ARROWS | {"delete", "forwarddelete"}
    held = [m for m, on in ((CTRL_, "cmd" in mods or "ctrl" in mods or word), (SHIFT, "shift" in mods), (ALT, "opt" in mods and not word)) if on]
    combo(held + [vk], max(1, min(n or 1, 200)))

def apply(c):
    global dragging
    if "ax" in c and "ay" in c:  # 0..1 do monitor principal (o que o vídeo mostra)
        w, h = u32.GetSystemMetrics(0), u32.GetSystemMetrics(1)
        u32.SetCursorPos(int(min(max(c["ax"], 0), 1) * (w - 1)), int(min(max(c["ay"], 0), 1) * (h - 1)))
    if "dx" in c or "dy" in c:
        p = W.POINT(); u32.GetCursorPos(ctypes.byref(p))
        u32.SetCursorPos(int(p.x + c.get("dx", 0)), int(p.y + c.get("dy", 0)))
    if "b" in c:
        dragging = c["b"] == "down"; _send(mouse(0x2 if dragging else 0x4))
    if "c" in c:
        dn, up = (0x8, 0x10) if c["c"] == 3 else (0x2, 0x4)
        _send(*[mouse(f) for f in (dn, up)] * (2 if c["c"] == 2 else 1))
    # Scroll natural como no Mac (píxeis -> unidades da roda: 120 = 1 "clique"; valores pequenos dão scroll suave)
    if c.get("sy"): _send(mouse(0x800, int(c["sy"] * 2)))
    if c.get("sx"): _send(mouse(0x1000, int(-c["sx"] * 2)))
    if c.get("t"):
        ins = []
        for ch in c["t"]:
            for unit in struct.unpack(f"<{len(ch.encode('utf-16-le')) // 2}H", ch.encode("utf-16-le")):
                if unit == 10: ins += [key(0x0D), key(0x0D, up=True)]
                else: ins += [key(uni=unit), key(uni=unit, up=True)]
        if ins: _send(*ins)
    if c.get("k"): press(c["k"], c.get("m"), c.get("n", 1))

def snapshot() -> bytes:
    """JPEG do monitor principal (fora de casa, pelo relay, quando não há vídeo direto)."""
    r = subprocess.run([config.ffmpeg(), "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "gdigrab", "-draw_mouse", "1", "-i", "desktop",
                        "-frames:v", "1", "-vf", "scale='min(1600,iw)':-2", "-q:v", "7", "-f", "mjpeg", "-"],
                       capture_output=True, timeout=10, creationflags=0x08000000)
    return r.stdout

if __name__ == "__main__":  # verificação: partir Annex B em frames e traduzir teclas não rebenta
    import io
    sps, pps, idr, p = b"\x67\x64\x00\x1f", b"\x68\xee\x3c", b"\x65\x88\x84", b"\x41\x9a\x02"
    aud = b"\x00\x00\x00\x01\x09\xf0"
    s = aud + b"\x00\x00\x00\x01" + sps + b"\x00\x00\x00\x01" + pps + b"\x00\x00\x01" + idr + aud + b"\x00\x00\x00\x01" + p + aud
    out = list(access_units(io.BufferedReader(io.BytesIO(s))))
    assert out[0] == bytes([1, 2]) + struct.pack(">H", 4) + sps + struct.pack(">H", 3) + pps + struct.pack(">I", 3) + idr, out[0]
    assert out[1] == b"\x00" + struct.pack(">I", 3) + p, out[1]
    print("ok")
