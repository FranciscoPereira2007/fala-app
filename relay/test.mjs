// Mac falso por WebSocket + iPhone falso por POST: eco com prefixo "R:".
const origin = process.argv[2] || "http://127.0.0.1:8798";
const room = "a".repeat(64), base = origin + "/r/" + room;
let ok = 0, fail = 0; const check = (c, n) => { console.log((c ? "OK   " : "FALHA ") + n); c ? ok++ : fail++; };
let r = await fetch(base + "/send", { method: "POST", body: new Uint8Array([1, 2, 3]) });
check(r.status === 503, "sem Mac: 503 (iPhone guarda na fila)");
const ws = new WebSocket(base.replace("http", "ws"), { headers: { "X-Mac-Proof": "p".repeat(40) } });
await new Promise((res, rej) => { ws.onopen = res; ws.onerror = (e) => rej(new Error("ws: " + (e.message || e.type))); setTimeout(() => rej(new Error("ws timeout")), 15000); }); ws.binaryType = "arraybuffer";
ws.onmessage = (e) => { if (typeof e.data === "string") return; const b = new Uint8Array(e.data); const out = new Uint8Array(b.length + 2); out.set(b.subarray(0, 8)); out.set([82, 58], 8); out.set(b.subarray(8), 10); ws.send(out); };
const t0 = Date.now();
r = await fetch(base + "/send", { method: "POST", body: new TextEncoder().encode("ola") });
check(r.status === 200 && new TextDecoder().decode(await r.arrayBuffer()) === "R:ola", `ida e volta pelo relay (${Date.now() - t0} ms)`);
const many = await Promise.all([...Array(5)].map((_, i) => fetch(base + "/send", { method: "POST", body: new TextEncoder().encode("p" + i) }).then((x) => x.text())));
check(many.every((x, i) => x === "R:p" + i), "5 pedidos ao mesmo tempo, cada um recebe a sua resposta");
r = await fetch(origin + "/r/" + "b".repeat(64) + "/send", { method: "POST", body: "x" });
check(r.status === 503, "outra sala não chega a este Mac");
// Túnel: o Mac falso abre o seu lado quando recebe "live:<sid>" e faz eco; o iPhone falso manda antes de o Mac chegar.
ws.addEventListener("message", (e) => {
  if (typeof e.data !== "string" || !e.data.startsWith("live:")) return;
  const h = new WebSocket(base.replace("http", "ws") + "/live/" + e.data.slice(5), { headers: { "X-Mac-Proof": "p".repeat(40) } });
  h.binaryType = "arraybuffer"; h.onmessage = (m) => h.send(m.data);
});
const ph = new WebSocket(base.replace("http", "ws") + "/live"); ph.binaryType = "arraybuffer";
await new Promise((res, rej) => { ph.onopen = res; ph.onerror = () => rej(new Error("túnel não abriu")); });
const got = []; const t1 = Date.now();
const done = new Promise((res) => { ph.onmessage = (m) => { got.push(new Uint8Array(m.data)[0]); if (got.length === 3) res(); }; setTimeout(res, 8000); });
for (const i of [7, 8, 9]) ph.send(new Uint8Array([i]));
await done;
check(got.join() === "7,8,9", `túnel: bytes vão e voltam pela ordem (${Date.now() - t1} ms)`);
const bad = new WebSocket(base.replace("http", "ws") + "/live/" + "0".repeat(32), { headers: { "X-Mac-Proof": "x".repeat(40) } });
check(await new Promise((res) => { bad.onopen = () => res(false); bad.onerror = () => res(true); setTimeout(() => res(true), 5000); }), "túnel: lado do Mac sem a prova certa é recusado");
ph.close(); ws.close(); console.log(fail ? `${fail} FALHAS` : "TUDO OK"); process.exit(fail ? 1 : 0);
