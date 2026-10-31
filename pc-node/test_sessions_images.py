"""python3 test_sessions_images.py: capturas das sessões Claude viram mensagens "Image · " (corre no Mac)."""
import base64, json, os, sys, tempfile
H = tempfile.mkdtemp(); os.environ["HOME"] = os.environ["USERPROFILE"] = H
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sessions
os.makedirs(os.path.join(H, ".claude", "projects", "p"))
png = base64.b64encode(b"\x89PNG fake").decode()
lines = [
    {"type": "assistant", "uuid": "a1", "timestamp": "2026-10-21T10:00:00Z", "message": {"content": [{"type": "tool_use", "name": "Read", "input": {"file_path": "C:\\Users\\x\\shot.png"}}]}},
    {"type": "user", "uuid": "u1", "timestamp": "2026-10-21T10:00:01Z", "message": {"content": [{"type": "tool_result", "content": [{"type": "image", "source": {"data": png, "media_type": "image/png"}}]}]}},
    {"type": "assistant", "uuid": "a2", "timestamp": "2026-10-21T10:00:01Z", "message": {"content": [{"type": "text", "text": "Vi."}]}},
    {"type": "user", "uuid": "u2", "timestamp": "2026-10-21T10:00:02Z", "message": {"content": [{"type": "tool_result", "content": [{"type": "text", "text": "x"}, {"type": "image", "source": {"data": png, "media_type": "image/jpeg"}}]}]}},
]
open(os.path.join(H, ".claude", "projects", "p", "s1.jsonl"), "w").write("\n".join(map(json.dumps, lines)))
m = [x["text"] for x in sessions.claude_messages("s1")]
assert m[0] == "Read · C:/Users/x/shot.png", m      # caminho todo da imagem lida
assert len(m) == 3 and m[1] == "Vi." and m[2].startswith("Image · ") and m[2].endswith("u2-0-1.jpg"), m  # u1 é a mesma foto do Read
f = m[2][len("Image · "):]
assert open(f, "rb").read() == b"\x89PNG fake"
assert sessions.media(f) == b"\x89PNG fake" and sessions.media(os.path.join(H, "fora.png")) is None
print("OK")
