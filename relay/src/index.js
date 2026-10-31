// Relay da Fala: o Mac mantém um WebSocket de saída aberto; o iPhone faz POST de um pedido já cifrado
// (LinkCrypto, chave = código de emparelhamento) e recebe a resposta cifrada do Mac. O relay só vê bytes.
// Sala = hash do código (64 hex). Sem Mac ligado: 503, e o iPhone guarda na fila como já faz.
// Túnel (ecrã ao vivo / chamada de qualquer rede): o iPhone abre WS em /r/<sala>/live, o relay manda "live:<sid>" ao Mac/PC,
// que abre WS em /r/<sala>/live/<sid> (com a prova) e liga-o à sua porta local. Daí em diante o relay só passa bytes cifrados.
// Contas (/a/...): "Entrar com a Apple" no iPhone; a conta guarda os computadores da pessoa (Mac/PC: nome, código, endereço
// de casa) para um iPhone novo os ter logo. Sessão = "<conta>.<segredo>"; a conta é o hash do id da Apple (sem email nem nome).
const APPLE_AUD = ["com.fran.fala.ios"];
const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, "0")).join("");
const sha = async (t) => hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(t)));
const b64u = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const json = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });
let appleKeys = null;

async function appleSub(jwt) {
  const [h, p, sig] = (jwt || "").split(".");
  if (!sig) return null;
  const head = JSON.parse(new TextDecoder().decode(b64u(h))), body = JSON.parse(new TextDecoder().decode(b64u(p)));
  if (!appleKeys || appleKeys.at < Date.now() - 3600e3) appleKeys = { at: Date.now(), keys: (await (await fetch("https://appleid.apple.com/auth/keys")).json()).keys };
  const jwk = appleKeys.keys.find((k) => k.kid === head.kid);
  if (!jwk || head.alg !== "RS256") return null;
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const ok = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, b64u(sig), new TextEncoder().encode(h + "." + p));
  if (!ok || body.iss !== "https://appleid.apple.com" || !APPLE_AUD.includes(body.aud) || body.exp * 1000 < Date.now()) return null;
  return body.sub;
}

async function account(req, env) {
  const url = new URL(req.url);
  if (url.pathname === "/a/login" && req.method === "POST") {
    const tok = (await req.json().catch(() => ({}))).token;
    // Só no `wrangler dev --var FALA_TEST:1` (testes): "test:<id>" entra sem a Apple. Em produção a variável não existe.
    const sub = env.FALA_TEST && String(tok).startsWith("test:") ? tok : await appleSub(tok).catch(() => null);
    if (!sub) return json({ error: "Login da Apple inválido" }, 401);
    const acc = await sha("fala-apple:" + sub);
    return env.ACCOUNT.get(env.ACCOUNT.idFromName(acc)).fetch(new Request("https://a/login", { method: "POST", headers: { "x-acc": acc } }));
  }
  const [acc, secret] = (req.headers.get("Authorization") || "").replace(/^Bearer /, "").split(".");
  if (!/^[0-9a-f]{64}$/.test(acc || "") || !secret) return json({ error: "Sem sessão" }, 401);
  const r = new Request("https://a" + url.pathname.slice(2) + url.search, { method: req.method, body: req.method === "GET" ? null : await req.text(), headers: { "x-acc": acc, "x-secret": secret } });
  return env.ACCOUNT.get(env.ACCOUNT.idFromName(acc)).fetch(r);
}

export class Account {
  constructor(state) { this.s = state.storage; }
  async fetch(req) {
    const path = new URL(req.url).pathname, acc = req.headers.get("x-acc");
    const sessions = (await this.s.get("sessions")) || [];
    if (path === "/login") {
      const secret = hex(crypto.getRandomValues(new Uint8Array(32)));
      await this.s.put("sessions", [...sessions.slice(-19), await sha(secret)]); // até 20 aparelhos com sessão
      return json({ session: acc + "." + secret, devices: (await this.s.get("devices")) || [] });
    }
    const mine = await sha(req.headers.get("x-secret") || "");
    if (!sessions.includes(mine)) return json({ error: "Sessão terminada" }, 401);
    let devices = (await this.s.get("devices")) || [];
    if (path === "/devices" && req.method === "GET") return json({ devices });
    if (path === "/device" && req.method === "POST") { // junta ou atualiza um computador (id = hash do código, calculado no iPhone)
      const d = await req.json().catch(() => ({}));
      const clean = { id: String(d.id || "").slice(0, 64), kind: d.kind === "pc" ? "pc" : "mac", name: String(d.name || "").slice(0, 60),
        code: String(d.code || "").slice(0, 64), lan: String(d.lan || "").slice(0, 80), at: Date.now() };
      if (!/^[0-9a-f]{16,64}$/.test(clean.id) || clean.code.length < 10) return json({ error: "Computador inválido" }, 400);
      devices = [...devices.filter((x) => x.id !== clean.id), clean].slice(-20);
      await this.s.put("devices", devices);
      return json({ devices });
    }
    if (path === "/device" && req.method === "DELETE") {
      const id = new URL(req.url).searchParams.get("id");
      devices = devices.filter((x) => x.id !== id); await this.s.put("devices", devices);
      return json({ devices });
    }
    if (path === "/logout" && req.method === "POST") { await this.s.put("sessions", sessions.filter((x) => x !== mine)); return json({ ok: true }); }
    if (path === "/account" && req.method === "DELETE") { await this.s.deleteAll(); return json({ ok: true }); } // apagar conta (App Store 5.1.1)
    return json({ error: "?" }, 404);
  }
}

import { privacy, support } from "../site/pages.js";
const page = (h) => new Response(h, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=300" } });

export default {
  async fetch(req, env) {
    const path = new URL(req.url).pathname;
    if (path === "/privacidade" || path === "/privacy") return page(privacy());
    if (path === "/suporte" || path === "/support") return page(support());
    if (path.startsWith("/a/")) return account(req, env);
    const m = new URL(req.url).pathname.match(/^\/r\/([0-9a-f]{64})(\/send|\/live(?:\/[0-9a-f]{32})?)?$/);
    if (!m) return new Response("Fala relay", { status: 404 });
    return env.ROOM.get(env.ROOM.idFromName(m[1])).fetch(req);
  },
};

export class Room {
  constructor(state) {
    this.state = state; this.waiting = new Map();
    // Ping/pong sem acordar o Durable Object (poupa a quota de duração).
    this.state.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  mac() { return this.state.getWebSockets("mac")[0]; }

  async proofOK(req) {
    const proof = req.headers.get("X-Mac-Proof") || "";
    if (proof.length < 32) return false;
    const h = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(proof)))].map((b) => b.toString(16).padStart(2, "0")).join("");
    return (await this.state.storage.get("mac")) === h;
  }

  pipe(tag) {
    const [client, server] = Object.values(new WebSocketPair());
    this.state.acceptWebSocket(server, [tag]);
    return [client, server];
  }

  async live(req) {
    if (req.headers.get("Upgrade") !== "websocket") return new Response("websocket", { status: 426 });
    const sid = new URL(req.url).pathname.split("/")[4];
    if (sid) { // lado do Mac/PC: só com a prova da sala
      if (!(await this.proofOK(req))) return new Response("prova errada", { status: 403 });
      const phone = this.state.getWebSockets("p:" + sid)[0];
      if (!phone) return new Response("iPhone já saiu", { status: 410 });
      const [client, server] = this.pipe("h:" + sid);
      for (const m of this.pending?.get(sid) || []) server.send(m);
      this.pending?.delete(sid);
      return new Response(null, { status: 101, webSocket: client });
    }
    const host = this.mac();
    if (!host) return new Response("Mac desligado", { status: 503 });
    if (this.state.getWebSockets().length > 40) return new Response("demasiadas ligações", { status: 429 });
    const id = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
    const [client] = this.pipe("p:" + id);
    host.send("live:" + id);
    return new Response(null, { status: 101, webSocket: client });
  }

  async fetch(req) {
    if (new URL(req.url).pathname.split("/")[3] === "live") return this.live(req);
    if (req.headers.get("Upgrade") === "websocket") {
      // Só o Mac verdadeiro: prova = HKDF(código, "fala-relay-mac"). A 1.ª prova fica guardada (hash); outras são recusadas.
      const proof = req.headers.get("X-Mac-Proof") || "";
      if (proof.length < 32) return new Response("sem prova", { status: 401 });
      const h = [...new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(proof)))].map((b) => b.toString(16).padStart(2, "0")).join("");
      const known = await this.state.storage.get("mac");
      if (known && known !== h) return new Response("Mac errado", { status: 403 });
      if (!known) await this.state.storage.put("mac", h);
      for (const old of this.state.getWebSockets("mac")) old.close(4000, "substituído"); // só um Mac por sala
      const [client, server] = Object.values(new WebSocketPair());
      this.state.acceptWebSocket(server, ["mac"]);
      return new Response(null, { status: 101, webSocket: client });
    }
    if (req.method !== "POST") return new Response("POST", { status: 405 });
    // Limite por sala: 240 pedidos por minuto chegam para uso normal (ecrã remoto ~3/s) e travam quem queira gastar a quota.
    const now = Date.now();
    if (now - (this.win || 0) > 60000) { this.win = now; this.count = 0; }
    if (++this.count > 240) return new Response("devagar", { status: 429 });
    const len = Number(req.headers.get("Content-Length") || 0);
    if (len > 4 << 20) return new Response("grande demais", { status: 413 });
    const body = new Uint8Array(await req.arrayBuffer());
    if (body.length > 4 << 20) return new Response("grande demais", { status: 413 });
    const ws = this.mac();
    if (!ws) return new Response("Mac desligado", { status: 503 });
    const id = crypto.getRandomValues(new Uint8Array(8));
    const key = [...id].join(".");
    const reply = new Promise((resolve) => {
      const t = setTimeout(() => { this.waiting.delete(key); resolve(null); }, 55000);
      this.waiting.set(key, (d) => { clearTimeout(t); resolve(d); });
    });
    const frame = new Uint8Array(8 + body.length); frame.set(id); frame.set(body, 8);
    ws.send(frame);
    const d = await reply;
    return d ? new Response(d, { headers: { "content-type": "application/octet-stream" } }) : new Response("Mac não respondeu", { status: 504 });
  }

  peer(ws) {
    const t = this.state.getTags(ws).find((x) => x.startsWith("p:") || x.startsWith("h:"));
    if (!t) return null;
    return { sid: t.slice(2), to: this.state.getWebSockets((t[0] === "p" ? "h:" : "p:") + t.slice(2))[0], phone: t[0] === "p" };
  }

  webSocketMessage(ws, msg) {
    const p = this.peer(ws);
    if (p) { // túnel: passa tal e qual; o que o iPhone manda antes de o Mac chegar fica à espera (máx. 64 mensagens)
      if (p.to) p.to.send(msg);
      else if (p.phone) {
        this.pending ??= new Map();
        const q = this.pending.get(p.sid) || [];
        if (q.length < 64) q.push(msg);
        this.pending.set(p.sid, q);
      }
      return;
    }
    if (typeof msg === "string") { if (msg === "ping") ws.send("pong"); return; }
    const b = new Uint8Array(msg);
    if (b.length < 8) return;
    const f = this.waiting.get([...b.subarray(0, 8)].join("."));
    if (f) { this.waiting.delete([...b.subarray(0, 8)].join(".")); f(b.subarray(8)); }
  }
  webSocketClose(ws, code) {
    const p = this.peer(ws);
    if (p?.to) try { p.to.close(1000, "fim"); } catch {}
    if (p) this.pending?.delete(p.sid);
  }
  webSocketError(ws) { this.webSocketClose(ws); }
}
