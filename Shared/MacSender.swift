import Foundation
import Network

/// Lado iPhone: encontra o Mac (Bonjour em casa, endereço Tailscale fora) e envia texto ou áudio.
///
/// Robustez:
/// - Tudo cifrado ponta a ponta com o código (LinkCrypto); o mesmo id em todas as tentativas, por isso
///   repetir é seguro (o Mac devolve a resposta guardada, nunca cola duas vezes).
/// - Tentativas com espera crescente (0,4 s, 0,8 s, 1,6 s...) até ao prazo, em todos os caminhos.
/// - Fila offline: o áudio que não chegou fica no disco e sai sozinho quando o Mac volta
///   (rede muda, app volta ao ecrã, ou de 20 em 20 s). Com mais de 90 s, o Mac só o põe no histórico.
/// - Ping com latência e caminho ("rede local" / "Tailscale") para o estado visível.
@MainActor final class MacSender: ObservableObject {
    @Published var macName: String?
    @Published var lastError: String?
    @Published private(set) var route: String?        // "rede local" | "Tailscale" | "endereço remoto"
    @Published private(set) var latencyMs: Int?
    @Published private(set) var lastSeen: Date?
    @Published private(set) var pending = 0
    private var browser: NWBrowser?
    private var endpoint: NWEndpoint?
    private var monitor: NWPathMonitor?
    private var timer: Timer?
    private var flushing = false
    /// Para testes (cliente no Mac): pasta da fila e endereços fixos.
    var outboxDir: URL
    var fixedEndpoints: [NWEndpoint]?
    var legacyFallback = false

    init(outboxDir: URL? = nil) {
        self.outboxDir = outboxDir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("outbox")
        try? FileManager.default.createDirectory(at: self.outboxDir, withIntermediateDirectories: true)
        pending = Self.items(in: self.outboxDir).count
    }

    // Guardado também no Porta-chaves partilhado: o widget (CarPlay) usa o mesmo código e endereço.
    static var host: String {
        get { shared("fala.macHost") }
        set { setShared(newValue.trimmingCharacters(in: .whitespaces), "fala.macHost") }
    }
    static var token: String {
        get { shared("fala.token") }
        set { setShared(newValue.uppercased().trimmingCharacters(in: .whitespaces), "fala.token") }
    }
    private static func shared(_ k: String) -> String {
        UserDefaults.standard.string(forKey: k) ?? FalaGroup.get(k) ?? ""
    }
    private static func setShared(_ v: String, _ k: String) {
        UserDefaults.standard.set(v, forKey: k); FalaGroup.set(v, k)
    }
    var paired: Bool { Self.paired }
    static var paired: Bool { !token.isEmpty }
    var hasMac: Bool { UserDefaults.standard.bool(forKey: "fala.demo") || paired && (endpoint != nil || !Self.host.isEmpty || fixedEndpoints != nil || Self.relayOn) }
    var label: String {
        if UserDefaults.standard.bool(forKey: "fala.demo") { return "Ligado via rede local · 18 ms" } // capturas (Demo; o widget não tem o Demo.swift)
        if let route, let lastSeen, Date().timeIntervalSince(lastSeen) < 120 {
            return "Ligado via \(route)" + (latencyMs.map { " · \($0) ms" } ?? "")
        }
        return macName ?? (Self.host.isEmpty ? "À procura do Mac…" : "Remoto: " + Self.host)
    }

    func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Link.type, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let first = results.first
            Task { @MainActor in
                self?.endpoint = first?.endpoint
                if case let .service(name, _, _, _)? = first?.endpoint { self?.macName = name } else { self?.macName = nil }
            }
        }
        b.start(queue: .main); browser = b
        // Rede mudou (Wi-Fi <-> dados, VPN liga): tenta já a fila.
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] p in if p.status == .satisfied { Task { @MainActor in await self?.flush() } } }
        m.start(queue: .main); monitor = m
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, self.pending > 0 { await self.flush() } }
        }
    }

    private struct Candidate { let ep: NWEndpoint?; let route: String } // ep nil = relay (qualquer rede)
    static var relayOn: Bool { !LinkCrypto.relayBase.isEmpty }

    /// Teste "pela internet": ignora a rede de casa e o Tailscale, vai só pelo relay.
    var onlyRelay = false

    private var candidates: [Candidate] {
        if onlyRelay { return Self.relayOn ? [Candidate(ep: nil, route: "internet")] : [] }
        if let fixedEndpoints { return fixedEndpoints.map { Candidate(ep: $0, route: "teste") } }
        var c: [Candidate] = []
        if let endpoint { c.append(Candidate(ep: endpoint, route: "rede local")) }
        let h = Self.host
        if !h.isEmpty {
            let parts = h.split(separator: ":")
            let name = String(parts[0]), port = parts.count == 2 ? UInt16(parts[1]) ?? Link.port : Link.port
            let ts = name.hasSuffix(".ts.net") || name.hasPrefix("100.") || !name.contains(".")
            c.append(Candidate(ep: .hostPort(host: NWEndpoint.Host(name), port: NWEndpoint.Port(rawValue: port)!), route: ts ? "Tailscale" : "endereço remoto"))
        }
        if Self.relayOn { c.append(Candidate(ep: nil, route: "internet")) }
        return c
    }

    /// Envia cifrado e espera a resposta (já decifrada). Repete com espera crescente até ao prazo.
    private func exchange(_ body: Data, id: Data = LinkCrypto.newID(), timeout: Double) async -> Data? {
        guard paired else { lastError = "Falta o código do Mac"; return nil }
        let token = Self.token
        let deadline = Date().addingTimeInterval(timeout)
        var backoff = 0.4, sawMac = false
        while deadline.timeIntervalSinceNow > 0.3 {
            let list = candidates
            if list.isEmpty { lastError = "Mac não encontrado"; return nil }
            for (i, c) in list.enumerated() {
                let left = deadline.timeIntervalSinceNow
                guard left > 0.3 else { break }
                let connectLimit = i < list.count - 1 ? min(3, left) : min(8, left)
                let payload = LinkCrypto.seal(body, id: id, token: token) // hora nova, mesmo id
                let t0 = Date()
                let res = c.ep.map { ep in { await Self.attempt(ep, payload, connectLimit: connectLimit, total: left) } } ?? { await Self.relayAttempt(payload, token: token, total: left) }
                switch await res() {
                case .reply(let d):
                    sawMac = true
                    if let plain = LinkCrypto.openReply(d, id: id, token: token) {
                        if plain == Data("B".utf8) { break } // o Mac ainda está a transcrever este pedido
                        latencyMs = Int(Date().timeIntervalSince(t0) * 1000); route = c.route; lastSeen = Date(); lastError = nil
                        return plain
                    }
                    if d == Data("N".utf8) {
                        // Mac antigo (v1) ou código errado: tenta v1 uma vez.
                        if legacyFallback, let ep = c.ep, case .reply(let r) = await Self.attempt(ep, Link.withToken(token, Self.v1Body(body)), connectLimit: connectLimit, total: max(1, deadline.timeIntervalSinceNow)), r != Data("N".utf8) {
                            route = c.route; lastSeen = Date(); lastError = nil; return r
                        }
                        lastError = "Código errado: copia o código do Mac"; return nil
                    }
                    lastError = "Resposta inválida do Mac"
                case .noConnect: continue
                case .noReply: sawMac = true // ligou mas caiu: repetir é seguro (mesmo id)
                }
            }
            let wait = min(backoff, max(0, deadline.timeIntervalSinceNow - 0.3))
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            backoff = min(backoff * 2, 4)
        }
        lastError = sawMac ? "O Mac não respondeu a tempo" : "Mac não encontrado"
        return nil
    }

    /// Pelo relay: POST do pedido já cifrado; 503 = Mac desligado (fica na fila), 504 = Mac não respondeu.
    nonisolated private static func relayAttempt(_ payload: Data, token: String, total: Double) async -> Outcome {
        guard let u = URL(string: LinkCrypto.relayBase + "/r/" + LinkCrypto.room(token) + "/send") else { return .noConnect }
        var r = URLRequest(url: u, timeoutInterval: max(2, min(total, 58)))
        r.httpMethod = "POST"; r.httpBody = payload
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse else { return .noConnect }
        switch h.statusCode {
        case 200: return .reply(d)
        case 503: return .noConnect
        default: return .noReply
        }
    }

    /// Corpo v2 -> v1 (Mac antigo): áudio volta a PCM em claro com o código.
    private static func v1Body(_ b: Data) -> Data {
        guard let m = b.first, [0x41, 0x61, 0x48].contains(m), b.count > 3 else { return b }
        let pcm = Link.decodeAudioV2(b)
        return Link.encodeAudio(pcm, paste: m == 0x41, enter: b[b.startIndex + 1] == 0x31)
    }

    private enum Outcome { case reply(Data), noConnect, noReply }

    nonisolated private static func attempt(_ ep: NWEndpoint, _ payload: Data, connectLimit: Double, total: Double) async -> Outcome {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.connectionTimeout = Int(max(1, connectLimit.rounded(.up)))
        let conn = NWConnection(to: ep, using: params)
        let q = DispatchQueue(label: "fala.link")
        return await withCheckedContinuation { c in
            var done = false, sent = false, buf = Data()
            func finish(_ o: Outcome) { q.async { if !done { done = true; conn.cancel(); c.resume(returning: o) } } }
            func read() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, complete, err in
                    if let d { buf.append(d) }
                    if let n = LinkCrypto.frameLength(buf), buf.count >= n { finish(.reply(Data(buf.prefix(n)))); return }
                    if complete || err != nil { finish(buf.isEmpty ? .noReply : .reply(buf)) } else { read() }
                }
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    sent = true
                    read() // a resposta pode chegar antes de o envio acabar de ser confirmado
                    // v2 leva o tamanho: não fecha o envio (half-close perdia a resposta). v1 precisa do fim.
                    conn.send(content: payload, isComplete: !LinkCrypto.isV2(payload), completion: .contentProcessed { _ in })
                case .failed, .cancelled: finish(sent ? .noReply : .noConnect)
                case .waiting: if !sent { finish(.noConnect) }
                default: break
                }
            }
            conn.start(queue: q)
            q.asyncAfter(deadline: .now() + connectLimit) { if !sent { finish(.noConnect) } }
            q.asyncAfter(deadline: .now() + total) { finish(sent ? .noReply : .noConnect) }
        }
    }

    // MARK: - API

    /// Ping: confirma código e caminho, mede a latência. Devolve o nome do Mac.
    /// Ping só pelo relay (prova que funciona fora de casa sem sair de casa).
    func pingInternet() async -> String? {
        onlyRelay = true; defer { onlyRelay = false }
        return await ping(timeout: 12)
    }

    @discardableResult func ping(timeout: Double = 6) async -> String? {
        guard let r = await exchange(Data("P".utf8), timeout: timeout), r.first == 0x50 else { return nil }
        let name = String(decoding: r.dropFirst(), as: UTF8.self)
        if macName == nil, !name.isEmpty { macName = name }
        return name
    }

    /// Envia o áudio (AAC); o Mac transcreve, cola e devolve o texto final. nil = não chegou a tempo:
    /// com `queueOnFail` fica na fila e o Mac recebe-o quando voltar.
    func sendAudio(_ samples: [Float], enter: Bool, paste: Bool = true, timeout: Double = 12, queueOnFail: Bool = false) async -> String? {
        guard !samples.isEmpty else { return nil }
        let aac = AudioCodec.encodeAAC(samples)
        let id = LinkCrypto.newID()
        let body = Link.encodeAudioV2(samples, mode: paste ? 0x41 : 0x61, enter: enter, compressed: aac)
        if let d = await exchange(body, id: id, timeout: timeout), d.first == 0x54 {
            return String(decoding: d.dropFirst(), as: UTF8.self)
        }
        if queueOnFail, paste, let aac { enqueue(id: id, aac: aac, enter: enter) }
        return nil
    }

    // MARK: - Jarvis

    /// O Mac tem o Jarvis? (ping "PJ": Mac antigo responde sem a capacidade e nunca recebe "J").
    @Published private(set) var jarvisReady = false

    @discardableResult func probeJarvis(timeout: Double = 6) async -> Bool {
        guard let r = await exchange(Data("PJ".utf8), timeout: timeout), r.first == 0x50 else { jarvisReady = false; return false }
        let lines = String(decoding: r.dropFirst(), as: UTF8.self).components(separatedBy: "\n")
        if macName == nil, let n = lines.first, !n.isEmpty { macName = n }
        jarvisReady = lines.contains(Jarvis.capability)
        return jarvisReady
    }

    func jarvis(_ req: Jarvis.Request, timeout: Double = 8) async -> Jarvis.Response? {
        if !jarvisReady, !(await probeJarvis()) { lastError = "O Mac precisa da Fala nova para o Jarvis"; return nil }
        guard let r = await exchange(Jarvis.encode("J", req), timeout: timeout), r.first == 0x4A else { return nil }
        return Jarvis.decode(Jarvis.Response.self, r)
    }

    /// Endereços a tentar para a chamada (mesma ordem do resto: rede local, depois Tailscale).
    var callEndpoints: [NWEndpoint] { candidates.compactMap(\.ep) } // chamadas só em ligação direta (casa ou Tailscale)

    /// Teclado remoto: texto (`t`) ou tecla (`k`) com modificadores (`m`: cmd, shift, opt, ctrl), `n` repetições.
    @discardableResult func key(text: String? = nil, key: String? = nil, mods: [String] = [], times: Int = 1) async -> Bool {
        var j: [String: Any] = [:]
        if let text { j["t"] = text }
        if let key { j["k"] = key; j["m"] = mods; j["n"] = times }
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return false }
        return await exchange(Data("K".utf8) + d, timeout: 6) == Data("ok".utf8)
    }

    /// Monitores do Mac (MacBook primeiro). Vazio = Mac antigo ou sem resposta.
    func monitors() async -> [(id: UInt32, name: String)] {
        guard let r = await exchange(Data("S".utf8) + Data(#"{"list":1}"#.utf8), timeout: 8), r.first == 0x44,
              let a = (try? JSONSerialization.jsonObject(with: Data(r.dropFirst()))) as? [[String: Any]] else { return [] }
        return a.compactMap { d in (d["id"] as? NSNumber).map { ($0.uint32Value, d["name"] as? String ?? "Ecrã") } }
    }

    /// Trackpad: {"dx","dy"} mover, {"c":1|2|3} clique, {"sx","sy"} scroll, {"b":"down"|"up"} arrastar (ver RemoteInput no Mac).
    @discardableResult func pointer(_ j: [String: Any]) async -> Bool {
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return false }
        return await exchange(Data("K".utf8) + d, timeout: 3) == Data("ok".utf8)
    }

    /// Ecrã do Mac. `have` = resumo (Link.digest) da imagem atual: se não mudou, devolve Data() vazio.
    /// Pela internet pede HEIC (metade do tamanho); na rede local JPEG (codifica 10x mais depressa).
    func screen(width: Int = 1280, x: Double? = nil, y: Double? = nil, right: Bool = false, double: Bool = false, scroll: Int? = nil, have: String? = nil, monitor: UInt32? = nil) async -> Data? {
        var j: [String: Any] = ["w": width, "q": route == "internet" ? 0.35 : 0.42]
        if let monitor { j["m"] = monitor }
        if route == "internet" { j["f"] = "heic" }
        if let have { j["h"] = have }
        if let x, let y { j["x"] = x; j["y"] = y; j["r"] = right; j["d"] = double }
        if let scroll { j["s"] = scroll }
        guard let d = try? JSONSerialization.data(withJSONObject: j), let r = await exchange(Data("S".utf8) + d, timeout: 15) else { return nil }
        if r.first == 0x53 { return Data(r.dropFirst()) }
        lastError = String(decoding: r.dropFirst(), as: UTF8.self); return nil
    }

    func send(_ text: String, enter: Bool) async -> Bool {
        await exchange(Data(((enter ? "1" : "0") + text).utf8), timeout: 6) == Data("ok".utf8)
    }

    // MARK: - Fila offline

    private struct Item: Codable { let id: Data; let created: Date; let enter: Bool }

    private static func items(in dir: URL) -> [(meta: URL, item: Item)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { u in
            (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(Item.self, from: $0) }.map { (u, $0) }
        }.sorted { $0.item.created < $1.item.created }
    }

    private func enqueue(id: Data, aac: Data, enter: Bool) {
        let name = id.map { String(format: "%02x", $0) }.joined()
        try? aac.write(to: outboxDir.appendingPathComponent(name + ".m4a"))
        try? JSONEncoder().encode(Item(id: id, created: Date(), enter: enter)).write(to: outboxDir.appendingPathComponent(name + ".json"))
        pending = Self.items(in: outboxDir).count
    }

    /// Envia o que ficou na fila. Recentes (< 90 s) colam; antigos só entram no histórico do Mac.
    func flush() async {
        guard !flushing, paired else { return }
        flushing = true; defer { flushing = false; pending = Self.items(in: outboxDir).count }
        for (meta, it) in Self.items(in: outboxDir) {
            let audioURL = meta.deletingPathExtension().appendingPathExtension("m4a")
            guard let aac = try? Data(contentsOf: audioURL) else { try? FileManager.default.removeItem(at: meta); continue }
            // Item de mais de 1 dia: descarta (o texto ficou no iPhone).
            if Date().timeIntervalSince(it.created) > 86400 { try? FileManager.default.removeItem(at: meta); try? FileManager.default.removeItem(at: audioURL); continue }
            let mode: UInt8 = Date().timeIntervalSince(it.created) < 90 ? 0x41 : 0x48
            let body = Data([mode, it.enter ? 0x31 : 0x30, 0x43]) + aac
            guard let r = await exchange(body, id: it.id, timeout: 20), r.first == 0x54 || r.first == 0x45 else { return } // Mac ainda fora: tenta depois
            try? FileManager.default.removeItem(at: meta); try? FileManager.default.removeItem(at: audioURL)
        }
    }
}
