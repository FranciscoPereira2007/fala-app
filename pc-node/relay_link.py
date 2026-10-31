"""PC no relay da Fala: o Mac (e o iPhone) chegam ao PC em qualquer rede, sem portas abertas.
WebSocket de saída para a sala do PC; cada pedido vem cifrado (ChaCha20-Poly1305, chave = HKDF(código, "fala-pc-relay-v1")),
é entregue ao servidor HTTP local (127.0.0.1:47900) e a resposta volta cifrada. O relay só vê bytes."""
import asyncio, base64, hashlib, hmac, json, os, time, urllib.request
import websockets
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

import config
RELAY = "wss://fala-relay.fancy-bird-92d5.workers.dev/r/"
status = {"relay": False}  # a janela mostra "ligada à internet"

def hkdf(code: str, salt: bytes, n=32) -> bytes:
    prk = hmac.new(salt, code.upper().encode(), hashlib.sha256).digest()
    return hmac.new(prk, b"\x01", hashlib.sha256).digest()[:n]

def main():
    code = config.code()
    key = ChaCha20Poly1305(hkdf(code, b"fala-pc-relay-v1"))
    room = hashlib.sha256(("fala-room-pc-v1:" + code.upper()).encode()).hexdigest()
    proof = hkdf(code, b"fala-relay-pc").hex()
    token = config.token()

    def handle(blob: bytes) -> bytes:
        nonce, ct = blob[:12], blob[12:]
        req = json.loads(key.decrypt(nonce, ct, None))
        if abs(time.time() - req.get("t", 0)) > 120: raise ValueError("pedido velho")
        r = urllib.request.Request(f"http://127.0.0.1:{config.PORT}" + req["p"], method=req.get("m", "GET"),
                                   data=base64.b64decode(req["b"]) if req.get("b") else None,
                                   headers={**req.get("h", {}), "X-Fala-Token": token})
        try:
            with urllib.request.urlopen(r, timeout=60) as res:
                out = {"s": res.status, "h": dict(res.headers), "b": base64.b64encode(res.read()).decode()}
        except urllib.error.HTTPError as e:
            out = {"s": e.code, "h": {}, "b": ""}
        n = os.urandom(12)
        return n + key.encrypt(n, json.dumps(out).encode(), None)

    async def tunnel(sid):
        """iPhone fora de casa quer o ecrã: WS do relay <-> porta local 47900 (o screen.py vê uma ligação normal)."""
        try:
            async with websockets.connect(RELAY + room + "/live/" + sid, additional_headers={"X-Mac-Proof": proof},
                                          max_size=8 << 20, ping_interval=20, write_limit=1 << 16) as tw:
                r, w = await asyncio.open_connection("127.0.0.1", config.PORT, limit=1 << 16)
                async def up():  # iPhone -> PC
                    async for m in tw:
                        if isinstance(m, bytes): w.write(m); await w.drain()
                    w.close()
                async def down():  # PC -> iPhone; o send espera pela rede: sem fila a crescer
                    while d := await r.read(1 << 16): await tw.send(d)
                    await tw.close()
                await asyncio.gather(up(), down(), return_exceptions=True)
        except Exception as e:
            print("túnel falhou:", e, flush=True)

    async def run():
        delay = 1
        while True:
            try:
                async with websockets.connect(RELAY + room, additional_headers={"X-Mac-Proof": proof}, max_size=8 << 20, ping_interval=None) as ws:
                    delay = 1; status["relay"] = True
                    print("ligado ao relay", flush=True)
                    async def pinger():
                        while True:
                            await asyncio.sleep(25); await ws.send("ping")
                    asyncio.create_task(pinger())
                    async for msg in ws:
                        if isinstance(msg, str):
                            if msg.startswith("live:"): asyncio.create_task(tunnel(msg[5:]))
                            continue
                        rid, blob = msg[:8], msg[8:]
                        try: reply = await asyncio.to_thread(handle, blob)
                        except Exception as e: print("pedido recusado:", e, flush=True); continue
                        await ws.send(rid + reply)
            except Exception as e:
                status["relay"] = False
                print("relay caiu:", e, "- volto em", delay, "s", flush=True)
                await asyncio.sleep(delay); delay = min(30, delay * 2)
    asyncio.run(run())

if __name__ == "__main__":
    main()
