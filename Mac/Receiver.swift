import SwiftUI
import AppKit
import Network
import CryptoKit

/// Recebe do iPhone: texto ou áudio (protocolo em Shared/Link.swift).
/// Ouve numa porta fixa (47800) anunciada por Bonjour: na rede local entra por Bonjour,
/// fora de casa entra pelo endereço Tailscale. Sem o código de emparelhamento certo, recusa.
@MainActor final class MacReceiver: ObservableObject {
    @Published var status = "A arrancar…"
    @Published var lastReceived: Date?
    @Published var token: String = MacReceiver.loadToken()
    @Published var remote: Tailscale.Info?
    @Published var lastPasteDebug = ""
    /// Último contacto do iPhone: quando e por onde ("rede local" / "Tailscale").
    @Published var lastContact: Date?
    @Published var lastRoute: String?
    let relay = RelayLink()
    private nonisolated let gate = ConnGate()
    @Published var queuedDelivered = 0
    private let replay = ReplayGuard()
    private(set) var port: UInt16 = Link.port
    private var listener: NWListener?

    static func loadToken() -> String {
        if let t = UserDefaults.standard.string(forKey: "fala.token"), t.count >= 26 { return t } // códigos antigos (10) são trocados
        let t = Link.newToken(); UserDefaults.standard.set(t, forKey: "fala.token"); return t
    }
    var pairURL: String {
        var c = URLComponents(); c.scheme = "fala"; c.host = "pair"
        c.queryItems = [.init(name: "t", value: token)] + ((remote?.dns ?? remote?.ip).map { [.init(name: "h", value: $0)] } ?? [])
        return c.string ?? ""
    }
    func regenerateToken() { token = Link.newToken(); UserDefaults.standard.set(token, forKey: "fala.token"); relay.start(token: token) }

    func start(store: Store, anyPort: Bool = false) {
        relay.onRequest = { [weak self] raw, out in self?.handleV2(raw, conn: nil, store: store, out: out) }
        relay.localPort = { [weak self] in self?.port ?? Link.port }
        RelayTunnel.log = { CallLog.w($0) }
        JarvisAPI.start() // o teu Jarvis manda nas sessões deste Mac (só 127.0.0.1)
        relay.start(token: token)
        guard listener == nil else { return }
        let fixed = anyPort ? nil : try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Link.port)!)
        guard let l = fixed ?? (try? NWListener(using: .tcp)) else { status = "Erro na rede local"; return }
        l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: Link.type)
        l.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = st { self.port = l.port?.rawValue ?? 0; self.status = "À escuta do iPhone" }
                if case .failed = st {
                    // 47800 ocupada (outra Fala aberta): ouve numa porta livre; o Bonjour anuncia-a.
                    if fixed != nil { l.cancel(); self.listener = nil; self.start(store: store, anyPort: true); return }
                    self.status = "Erro na rede local"
                }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            // Limites contra abuso na rede: 8 ligações em leitura, 16 MB por pedido, 20 s para chegar inteiro.
            guard let self, self.gate.enter() else { conn.cancel(); return }
            let gate = self.gate
            var counted = true
            func done() { if counted { counted = false; gate.leave() } }
            conn.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if counted { done(); conn.cancel() } }
            var buf = Data()
            func read() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, complete, err in
                    if let d { buf.append(d) }
                    if buf.count > 16 << 20 { done(); conn.cancel(); return } // > ~1 h de AAC: lixo
                    let n = LinkCrypto.frameLength(buf)
                    let full = n.map { buf.count >= $0 } ?? false
                    // Só o 1.º frame: numa chamada ("C") o resto da ligação é do CallServer.
                    let first = n.map { Data(buf.prefix($0)) } ?? buf
                    if full || complete || err != nil { done(); Task { @MainActor in self.handle(first, conn: conn, store: store) } } else { read() }
                }
            }
            read()
        }
        l.start(queue: .main); listener = l
        Task { remote = await Tailscale.info() }
    }

    func refreshRemote() { Task { remote = await Tailscale.info() } }

    private func reply(_ conn: NWConnection, _ s: String) {
        conn.send(content: Data(s.utf8), isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func handle(_ raw: Data, conn: NWConnection, store: Store) {
        if LinkCrypto.isV2(raw) {
            handleV2(raw, conn: conn, store: store) { out in conn.send(content: out, isComplete: true, completion: .contentProcessed { _ in conn.cancel() }) }
            return
        }
        reply(conn, "N") // ponytail: v1 (código em claro) removido por segurança; todos os iPhones falam v2
    }

    /// v2: decifra, anti-replay, e responde cifrado. Um retry com o mesmo id recebe a resposta guardada.
    /// `conn` nil = pedido que chegou pelo relay (sem ligação direta: sem chamadas).
    func handleV2(_ raw: Data, conn: NWConnection?, store: Store, out: @escaping (Data) -> Void) {
        guard let req = LinkCrypto.open(raw, token: token) else { out(Data("N".utf8)); return }
        let send: (Data) -> Void = { [token] body in out(LinkCrypto.sealReply(body, id: req.id, token: token)) }
        switch replay.check(req) {
        case .stale: send(Data("E".utf8)); return
        case .duplicate(let cached): send(cached ?? Data("B".utf8)); return
        case .fresh: break
        }
        touch(conn)
        let b = req.body
        guard let m = b.first else { conn?.cancel(); return }
        let finish: (Data) -> Void = { [replay] out in replay.store(req.id, reply: out); send(out) }
        switch m {
        case 0x50: // ping ("PJ" = ping com capacidades: o iPhone novo descobre o Jarvis)
            let jarvis = b.count > 1 && b[b.startIndex + 1] == 0x4A
            finish(Data(("P" + (Host.current().localizedName ?? "Mac") + (jarvis ? "\n" + Jarvis.capability : "")).utf8))
        case 0x4A: // Jarvis: pedido JSON (lista, mensagens, enviar, eventos)
            guard let jr = Jarvis.decode(Jarvis.Request.self, b) else { finish(Jarvis.encode("J", Jarvis.Response(ok: false, error: "Pedido inválido"))); return }
            Task.detached { finish(Jarvis.encode("J", SessionHub.shared.handle(jr))) }
        case 0x43: // chamada: aperto de mão; a ligação fica aberta para o CallServer
            guard let conn, let cs = Jarvis.decode(Jarvis.CallStart.self, b) else { send(Data("E".utf8)); return }
            let nonce = LinkCrypto.newID()
            let reply = Data("C".utf8) + nonce
            replay.store(req.id, reply: Data("E".utf8)) // um retry deste pedido não abre 2.ª chamada
            conn.send(content: LinkCrypto.sealReply(reply, id: req.id, token: token), completion: .contentProcessed { _ in })
            let server = CallServer(conn: conn, sessionID: cs.session, key: CallFrame.key(token: token, requestID: req.id, nonce: nonce)) { pcm in
                await WhisperEngine.shared.transcribe(pcm, waitForModel: true) ?? ""
            }
            server.start()
        case 0x56: // "V" + JSON {"w","mon"}: ecrã ao vivo (H.264); aperto de mão e a ligação fica aberta para o ScreenStream
            guard let conn else { send(Data("E".utf8)); return }
            let cmd = (try? JSONSerialization.jsonObject(with: Data(b.dropFirst()))) as? [String: Any]
            let nonce = LinkCrypto.newID()
            replay.store(req.id, reply: Data("E".utf8))
            conn.send(content: LinkCrypto.sealReply(Data("V".utf8) + nonce, id: req.id, token: token), completion: .contentProcessed { _ in })
            ScreenStream(conn: conn, key: CallFrame.key(token: token, requestID: req.id, nonce: nonce),
                         width: cmd?["w"] as? Int ?? 1600, monitor: (cmd?["mon"] as? NSNumber)?.uint32Value, relay: cmd?["r"] as? Int == 1).start()
        case 0x41, 0x61, 0x48: // áudio: cola / teste / só histórico
            let enter = b.count > 1 && b[b.startIndex + 1] == 0x31
            Task { @MainActor in
                let pcm = await Task.detached { Link.decodeAudioV2(b) }.value
                let text = await transcribeAndDeliver(pcm, mode: m, enter: enter, conn: conn, store: store)
                finish(Data((text.map { "T" + $0 } ?? "E").utf8))
            }
        case 0x53: // "S": ecrã do Mac (JPEG); "S" + JSON {"x","y","r","d","s","w","q","f","h"} = clique/scroll e devolve o ecrã novo
            let cmd = (try? JSONSerialization.jsonObject(with: Data(b.dropFirst()))) as? [String: Any]
            let md = (cmd?["m"] as? NSNumber)?.uint32Value // monitor escolhido (nil = principal)
            Task { @MainActor in
                if cmd?["list"] != nil { // lista de monitores: "D" + JSON [{"id","name"}]
                    finish(Data("D".utf8) + ((try? JSONSerialization.data(withJSONObject: await RemoteScreen.list())) ?? Data("[]".utf8))); return
                }
                if let x = cmd?["x"] as? Double, let y = cmd?["y"] as? Double {
                    RemoteScreen.click(x: x, y: y, right: cmd?["r"] as? Bool ?? false, double: cmd?["d"] as? Bool ?? false, display: md)
                    try? await Task.sleep(for: .milliseconds(250))
                } else if let dy = cmd?["s"] as? Int { RemoteScreen.scroll(dy: Int32(dy)); try? await Task.sleep(for: .milliseconds(150)) }
                let w = cmd?["w"] as? Int ?? 1280, q = cmd?["q"] as? Double ?? 0.55
                if let img = await RemoteScreen.snapshot(width: min(max(w, 480), 1920), quality: min(max(q, 0.2), 0.9), heic: cmd?["f"] as? String == "heic", display: md) {
                    // "h" = resumo da imagem que o iPhone já tem: igual -> "S" vazio (não muda, não gasta rede)
                    finish(Data("S".utf8) + (cmd?["h"] as? String == Link.digest(img) ? Data() : img))
                }
                else { finish(Data("ESem permissão de Gravação de Ecrã no Mac".utf8)) }
            }
        case 0x4B: // "K": teclado remoto (texto e teclas, como se estivesses ao teclado do Mac)
            guard let c = try? JSONDecoder().decode(RemoteInput.Cmd.self, from: Data(b.dropFirst())) else { finish(Data("E".utf8)); return }
            lastReceived = Date()
            finish(Data((RemoteInput.apply(c).map { "E" + $0 } ?? "ok").utf8))
        default: // texto
            let text = String(String(decoding: b, as: UTF8.self).dropFirst())
            Paster.paste(text, enter: m == 0x31)
            store.add(text, toMac: true)
            lastReceived = Date()
            finish(Data("ok".utf8))
        }
    }

    private func touch(_ conn: NWConnection?) {
        lastContact = Date()
        guard let conn else { lastRoute = "relay"; return }
        if case let .hostPort(host, _) = conn.endpoint {
            let h = "\(host)"
            lastRoute = h.hasPrefix("100.") || h.lowercased().hasPrefix("fd7a:115c:a1e0") ? "Tailscale" : "rede local"
        }
    }

    /// Transcreve e entrega. "A" cola (se o iPhone ainda espera), "H" só histórico (fila atrasada), "a" teste.
    private func transcribeAndDeliver(_ pcm: [Float], mode: UInt8, enter: Bool, conn: NWConnection?, store: Store) async -> String? {
        let raw = await WhisperEngine.shared.transcribe(pcm, waitForModel: true) ?? ""
        if raw.isEmpty, WhisperEngine.shared.lastError != nil { return nil }
        var text = await TechFix.apply(store.process(raw))
        if mode == 0x41 { text = await MainActor.run { ContextFormat.apply(text) } } // vai colar aqui: num e-mail sai como e-mail
        var alive = false
        if let conn { if case .ready = conn.state { alive = true } } else { alive = true } // relay: o iPhone ainda espera // iPhone desistiu (timeout) = já colou o texto dele
        if mode == 0x41, !text.isEmpty, alive {
            Paster.paste(text, enter: enter)
            store.add(text, toMac: true, seconds: Double(pcm.count) / 16000)
            lastReceived = Date()
        } else if mode == 0x48, !text.isEmpty {
            store.add(text, toMac: true, seconds: Double(pcm.count) / 16000)
            queuedDelivered += 1
        }
        lastPasteDebug = UserDefaults.standard.string(forKey: "fala.debug") ?? ""
        return text
    }
}

/// Lê o estado do Tailscale (sem login, sem mexer na conta).
enum Tailscale {
    struct Info: Equatable { var ip: String?; var dns: String?; var running: Bool; var note: String }

    static func info() async -> Info {
        await Task.detached {
            let bins = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            guard let bin = bins.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return Info(ip: nil, dns: nil, running: false, note: "Tailscale não instalado")
            }
            // tailscaled em modo utilizador (brew) usa um socket próprio; tenta esse primeiro.
            let alt = NSHomeDirectory() + "/Library/Application Support/tailscale-mc/tailscaled.sock"
            var out = FileManager.default.fileExists(atPath: alt) ? run(bin, ["--socket=" + alt, "status", "--json"]) : ""
            if !out.contains("\"Self\"") { out = run(bin, ["status", "--json"]) }
            guard let d = out.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                return Info(ip: nil, dns: nil, running: false, note: "Tailscale desligado")
            }
            let me = j["Self"] as? [String: Any]
            let ip = (me?["TailscaleIPs"] as? [String])?.first { $0.contains(".") }
            var dns = me?["DNSName"] as? String; if dns?.hasSuffix(".") == true { dns?.removeLast() }
            let running = (j["BackendState"] as? String) == "Running"
            return Info(ip: ip, dns: (dns?.isEmpty ?? true) ? nil : dns, running: running, note: running ? "Ligado" : "Tailscale: \(j["BackendState"] as? String ?? "?")")
        }.value
    }

    private static func run(_ bin: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Ligação de saída ao relay: o iPhone chega ao Mac em qualquer rede, sem VPN nem portas abertas.
/// Reabre sozinha (backoff até 30 s) e manda "ping" a cada 25 s para a ligação não cair.
@MainActor final class RelayLink {
    private var task: URLSessionWebSocketTask?
    private var room = ""
    private var proof = ""
    private var retry: Double = 1
    private(set) var connected = false
    var onRequest: ((Data, @escaping (Data) -> Void) -> Void)?
    var localPort: () -> UInt16 = { Link.port }

    func start(token: String) {
        let r = LinkCrypto.room(token)
        guard r != room || task == nil else { return }
        room = r; task?.cancel(with: .goingAway, reason: nil); task = nil
        // Prova de que este é o Mac (o relay guarda-a e recusa outros): HKDF(código, "fala-relay-mac").
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.uppercased().utf8)), salt: Data("fala-relay-mac".utf8), outputByteCount: 32)
        proof = k.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        open()
    }

    private func open() {
        guard !LinkCrypto.relayBase.isEmpty,
              let u = URL(string: LinkCrypto.relayBase.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") + "/r/" + room) else { return }
        var rq = URLRequest(url: u); rq.setValue(proof, forHTTPHeaderField: "X-Mac-Proof")
        let t = URLSession.shared.webSocketTask(with: rq)
        task = t; t.resume()
        receive(t); ping(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] r in
            Task { @MainActor in
                guard let self, t === self.task else { return }
                switch r {
                case .failure: self.connected = false; self.reopen()
                case .success(let m):
                    self.connected = true; self.retry = 1
                    // iPhone fora de casa quer o ecrã ao vivo ou uma chamada: túnel do relay para a nossa porta.
                    if case .string(let s) = m, s.hasPrefix("live:") { RelayTunnel.host(room: self.room, sid: String(s.dropFirst(5)), proof: self.proof, port: self.localPort()) }
                    if case .data(let d) = m, d.count > 8 {
                        let id = d.prefix(8)
                        self.onRequest?(Data(d.dropFirst(8))) { out in t.send(.data(id + out)) { _ in } }
                    }
                    self.receive(t)
                }
            }
        }
    }

    private func ping(_ t: URLSessionWebSocketTask) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard let self, t === self.task else { return }
            t.send(.string("ping")) { _ in }
            self.ping(t)
        }
    }

    private func reopen() {
        task = nil
        let d = retry; retry = min(30, retry * 2)
        Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(d)); if self?.task == nil { self?.open() } }
    }
}

/// Contador de ligações em leitura (máx. 8), seguro entre filas.
final class ConnGate: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func enter() -> Bool { lock.withLock { guard n < 8 else { return false }; n += 1; return true } }
    func leave() { lock.withLock { n = max(0, n - 1) } }
}
