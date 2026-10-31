"""Voz feminina natural pt-PT (Chatterbox multilingue, GPU) só para o server.py local (127.0.0.1:47901).
POST texto -> PCM Int16 a 22050 Hz (a mesma taxa da chamada)."""
import os, threading, torch, torchaudio
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from chatterbox.mtl_tts import ChatterboxMultilingualTTS

HERE = os.path.dirname(os.path.abspath(__file__))
W = os.path.expanduser(r"~\Documents\Codex\2026-10-11\l-c-users-perei-documents-codex\work\chatterbox-model")
REF = os.path.join(HERE, "voices", "ref-feminina.wav")
M = ChatterboxMultilingualTTS.from_local(W, device="cuda")
M.prepare_conditionals(REF)  # voz de referência carregada uma vez
LOCK = threading.Lock()
RS = torchaudio.transforms.Resample(M.sr, 22050)

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        text = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode("utf-8")[:600]
        with LOCK, torch.inference_mode():
            wav = M.generate(text, language_id="pt")
        pcm = (RS(wav.cpu()).clamp(-1, 1) * 32767).to(torch.int16).numpy().tobytes()
        self.send_response(200); self.send_header("Content-Length", str(len(pcm))); self.end_headers(); self.wfile.write(pcm)
    def log_message(self, *a): pass

if __name__ == "__main__":
    print("voz pronta", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 47901), H).serve_forever()
