"""Fala para Windows (servidor): ecrã e rato para o iPhone, colar ditados, sessões Claude/Codex; com GPU NVIDIA também Whisper e voz.
POST /stt  corpo = PCM float32 LE 16 kHz mono; header X-Prompt = vocabulário  -> JSON {text, secs}
POST /tts  corpo = texto UTF-8                                                -> PCM int16 LE, header X-Rate
GET  /health                                                                   -> JSON {ok, gpu}
POST /paste  corpo = texto; header X-Enter: 1 = carrega Enter depois de colar
GET  /screen  -> JPEG do ecrã; POST /input  corpo = JSON do rato/teclas (ver screen.py)
POST /jarvis {"text"} -> {"job"}; GET /jarvis?job= -> resposta do teu Jarvis (Codex ou Claude, conta da pessoa)
GET  /file?path= -> imagem de uma sessão; POST /mode {"id","text"} -> modo de permissões
GET  /accounts -> contas Claude/ChatGPT deste PC; POST /accounts/login {"which": "claude"|"codex"} abre o login no PC
Ligação que começa por "F2" = ecrã ao vivo (screen.py), na mesma porta.
Rede local com X-Fala-Token (config.token()); de fora entra pelo relay (relay_link.py), cifrado com o código."""
import json, os, sys, time, threading, hmac, re, urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import config, accounts, jarvis

HERE = config.HERE
# Bibliotecas CUDA vindas do pip (cuBLAS/cuDNN) no PATH antes de carregar o ctranslate2.
for pkg in ("cublas", "cudnn"):
    d = os.path.join(HERE, ".venv", "Lib", "site-packages", "nvidia", pkg, "bin")
    if os.path.isdir(d):
        os.add_dll_directory(d); os.environ["PATH"] = d + os.pathsep + os.environ["PATH"]

import sessions, screen
from urllib.parse import urlparse, parse_qs

TOKEN = config.token()
MODEL = VOICE = None  # Whisper/voz só com GPU NVIDIA e os pacotes instalados (a app normal não os traz: o iPhone transcreve)
try:
    import numpy as np
    from faster_whisper import WhisperModel
    MODEL = WhisperModel("large-v3-turbo", device="cuda", compute_type="int8_float16")
    from piper import PiperVoice
    VOICE = PiperVoice.load(os.path.join(HERE, "voices", "pt_PT-tugao-medium.onnx"))
except Exception as e:
    print("sem Whisper/voz neste PC:", type(e).__name__, flush=True)
LOCK = threading.Lock()  # uma GPU de 6 GB: um pedido de cada vez

def stt(pcm, prompt, beam=5):  # beam 5: menos palavras inventadas com ruído (medido: 12 vs 13 erros em 53), mesma velocidade
    segs, _ = MODEL.transcribe(pcm, language="pt", beam_size=beam, vad_filter=True,
                               initial_prompt=prompt or None, condition_on_previous_text=False)
    out = []
    for s in segs:
        if s.no_speech_prob > 0.6 and s.avg_logprob < -0.5: continue  # alucinação em silêncio
        out.append(s.text)
    t = " ".join(out).strip()
    return re.sub(r"\s+", " ", t)

def tts(text):
    chunks = [c.audio_int16_bytes for c in VOICE.synthesize(text)]
    return b"".join(chunks), VOICE.config.sample_rate

def paste(text, enter=False):
    import ctypes, subprocess, base64  # base64 por env: acentos chegam intactos ao clipboard
    env = dict(os.environ, FALA_T=base64.b64encode(text.encode("utf-8")).decode())
    subprocess.run(["powershell", "-NoProfile", "-Command",
                    "Set-Clipboard ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:FALA_T)))"], env=env, timeout=5,
                   creationflags=0x08000000)  # sem janela preta (a app corre sem consola)
    k = ctypes.windll.user32.keybd_event  # Ctrl down, V down, V up, Ctrl up
    k(0x11, 0, 0, 0); k(0x56, 0, 0, 0); k(0x56, 0, 2, 0); k(0x11, 0, 2, 0)
    if enter: time.sleep(0.12); k(0x0D, 0, 0, 0); k(0x0D, 0, 2, 0)  # como no Mac: Enter 0,12 s depois de colar

class H(BaseHTTPRequestHandler):
    def handle(self):
        if self.request.recv(2, 2) == b"F2": screen.serve(self.request); return  # MSG_PEEK: ecrã ao vivo
        super().handle()
    def _auth(self):
        if hmac.compare_digest(self.headers.get("X-Fala-Token", ""), TOKEN): return True
        self.send_response(401); self.end_headers(); return False
    def _send(self, code, body, ctype="application/json", extra=None):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if not self._auth(): return
        u = urlparse(self.path); q = parse_qs(u.query)
        if u.path == "/health":
            self._send(200, json.dumps({"ok": True, "gpu": "cuda" if MODEL else "none", "name": config.name(), "app": 2}).encode())
        elif u.path == "/jarvis/config":
            self._send(200, json.dumps(jarvis.config_get()).encode())
        elif u.path == "/jarvis":  # resultado de um pedido ao Jarvis (ver POST /jarvis)
            self._send(200, json.dumps(jarvis.result(q.get("job", [""])[0]), ensure_ascii=False).encode())
        elif u.path == "/accounts":
            self._send(200, json.dumps(accounts.status()).encode())
        elif u.path == "/screen":
            self._send(200, screen.snapshot(), "image/jpeg")
        elif u.path == "/sessions":
            self._send(200, json.dumps(sessions.list_all()).encode())
        elif u.path == "/file":  # imagem/vídeo de uma sessão (só pastas permitidas)
            d = sessions.media(q.get("path", [""])[0])
            if d is None: self._send(404, b"{}")
            else: self._send(200, d, "application/octet-stream")
        elif u.path == "/tail":
            self._send(200, json.dumps(sessions.messages(q.get("id", [""])[0], int(q.get("limit", ["60"])[0]))).encode())
        else:
            self._send(404, b"{}")
    def do_POST(self):
        if not self._auth(): return
        n = int(self.headers.get("Content-Length", "0"))
        if n > 64 << 20: self._send(413, b"{}"); return
        body = self.rfile.read(n); t0 = time.time()
        if self.path == "/send":
            j = json.loads(body or b"{}"); err = sessions.send(j.get("id", ""), j.get("text", ""))
            self._send(200, json.dumps({"ok": err is None, "error": err}).encode()); return
        if self.path == "/mode":  # modo de permissões de uma sessão Claude (default | acceptEdits | plan | bypassPermissions)
            j = json.loads(body or b"{}"); err = sessions.set_mode(j.get("id", ""), j.get("text", ""))
            self._send(200, json.dumps({"ok": err is None, "error": err}).encode()); return
        if self.path == "/paste":  # ditado do iPhone com destino PC: clipboard + Ctrl+V na janela ativa
            paste(body.decode("utf-8"), self.headers.get("X-Enter") == "1")
            self._send(200, b'{"ok": true}'); return
        if self.path == "/jarvis/config":  # motor, modelo e acesso do Jarvis (do iPhone)
            self._send(200, json.dumps(jarvis.config_set(json.loads(body or b"{}"))).encode()); return
        if self.path == "/new":  # sessão nova (o Jarvis usa-a para lançar trabalho noutra pasta)
            j = json.loads(body or b"{}"); self._send(200, json.dumps(jarvis.new_session(j.get("cwd", ""), j.get("prompt", ""))).encode()); return
        if self.path == "/jarvis":  # o teu Jarvis (chat e chamada do iPhone): devolve um id, a resposta vem por GET
            text = json.loads(body or b"{}").get("text", "")
            self._send(200, json.dumps({"job": jarvis.start(text)}).encode()); return
        if self.path == "/accounts/login":  # do iPhone: abre o login do Claude/ChatGPT no browser do PC
            which = json.loads(body or b"{}").get("which", "")
            msg = accounts.login(which) if which in ("claude", "codex") else "?"
            self._send(200, json.dumps({"ok": which in ("claude", "codex"), "message": msg}).encode()); return
        if self.path == "/input":  # rato/teclas sem vídeo direto (fora de casa, pelo relay)
            screen.apply(json.loads(body or b"{}")); self._send(200, b'{"ok": true}'); return
        if self.path in ("/stt", "/tts") and not MODEL:
            self._send(503, b'{"error": "sem GPU"}'); return  # o iPhone/Mac fazem eles
        with LOCK:
            if self.path == "/stt":
                pcm = np.frombuffer(body, dtype="<f4")
                text = stt(pcm, self.headers.get("X-Prompt", ""), int(self.headers.get("X-Beam", "5") or 5))
                self._send(200, json.dumps({"text": text, "secs": round(time.time() - t0, 3)}).encode())
            elif self.path == "/tts":
                text = body.decode("utf-8")
                if self.headers.get("X-Voice", "") == "chatterbox":
                    try:  # voz natural feminina (cb_server.py); se não estiver, cai na Piper
                        r = urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:47901", data=body, method="POST"), timeout=30)
                        self._send(200, r.read(), "application/octet-stream", {"X-Rate": "22050", "X-Voice": "chatterbox"}); return
                    except Exception:
                        pass
                pcm, rate = tts(text)
                self._send(200, pcm, "application/octet-stream", {"X-Rate": str(rate)})
            else:
                self._send(404, b"{}")
    def log_message(self, *a): pass

def start(port=config.PORT):
    """Servidor HTTP + relay em fundo. Erro se a porta estiver ocupada (outra Fala aberta)."""
    srv = ThreadingHTTPServer(("0.0.0.0", port), H)
    if MODEL: stt(np.zeros(16000, dtype=np.float32), "")  # aquece o modelo
    import relay_link
    threading.Thread(target=relay_link.main, daemon=True).start()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    threading.Thread(target=accounts.status, daemon=True).start()  # aquece o estado das contas
    print(f"Fala pronta na porta {port}", flush=True)
    return srv

if __name__ == "__main__":  # sem janela (instalação antiga do Fran / tarefa agendada)
    start(int(sys.argv[1]) if len(sys.argv) > 1 else config.PORT)
    threading.Event().wait()
