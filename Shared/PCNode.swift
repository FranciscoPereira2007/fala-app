import Foundation
import CryptoKit
import Network

/// PC Windows com GPU (pc-node/server.py): faz o Whisper e a voz para o MacBook não aquecer, e mostra as sessões do PC.
/// Em casa vai direto pela rede local; noutro sítio vai pelo relay, cifrado ponta a ponta (o relay só vê bytes).
/// Se o PC não responder, tudo volta a correr no Mac sozinho.
enum PCNode {
    /// Endereço na rede de casa (opcional). Sem ele, só o relay.
    static var lanBase: String? {
        let lan = UserDefaults.standard.string(forKey: "fala.pcNode") ?? "" // iPhone: vem do QR do PC; Mac: escolhido à mão
        return lan.isEmpty ? nil : "http://" + lan
    }
    /// iPhone: código do PC (QR da app Windows). Mac: o PC usa o código do Mac e só se houver endereço (fala.pcNode).
    static var code: String {
        #if os(iOS)
        UserDefaults.standard.string(forKey: "fala.pcCode") ?? ""
        #else
        UserDefaults.standard.string(forKey: "fala.token") ?? ""
        #endif
    }
    static var configured: Bool {
        #if os(iOS)
        !code.isEmpty
        #else
        !code.isEmpty && lanBase != nil && UserDefaults.standard.bool(forKey: "fala.pcOff") == false
        #endif
    }

    private static func hkdf(_ salt: String, _ n: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.uppercased().utf8)), salt: Data(salt.utf8), outputByteCount: n)
            .withUnsafeBytes { Data($0) }
    }
    /// Token só do PC na rede local: HKDF(código, "fala-pc-v1").
    static var token: String { hkdf("fala-pc-v1", 24).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-") }
    private static var relayKey: SymmetricKey { SymmetricKey(data: hkdf("fala-pc-relay-v1", 32)) }
    static var room: String { SHA256.hash(data: Data(("fala-room-pc-v1:" + code.uppercased()).utf8)).map { String(format: "%02x", $0) }.joined() }
    private static var relayURL: URL? { URL(string: LinkCrypto.relayBase + "/r/" + room + "/send") }

    nonisolated(unsafe) private static var lanUntil = Date.distantPast, lanDownUntil = Date.distantPast
    nonisolated(unsafe) private static var upUntil = Date.distantPast, downUntil = Date.distantPast

    /// Pedido ao PC: rede local se estiver lá, senão relay cifrado. Devolve (estado, cabeçalhos, corpo).
    static func request(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil, timeout: Double) async -> (Int, [String: String], Data)? {
        guard configured else { return nil }
        if let lan = lanBase, Date() > lanDownUntil, let u = URL(string: lan + path) {
            var r = URLRequest(url: u, timeoutInterval: Date() < lanUntil ? timeout : min(timeout, 2))
            r.httpMethod = method; r.httpBody = body; r.setValue(token, forHTTPHeaderField: "X-Fala-Token")
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            if let (d, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse {
                lanUntil = Date().addingTimeInterval(60)
                return (h.statusCode, h.allHeaderFields.reduce(into: [:]) { $0["\($1.key)"] = "\($1.value)" }, d)
            }
            lanDownUntil = Date().addingTimeInterval(30) // fora de casa: não tenta a LAN durante 30 s
        }
        // Relay: {m, p, h, b, t} cifrado com ChaChaPoly; a resposta {s, h, b} também.
        guard let url = relayURL else { return nil }
        var env: [String: Any] = ["m": method, "p": path, "h": headers, "t": Date().timeIntervalSince1970]
        if let body { env["b"] = body.base64EncodedString() }
        guard let plain = try? JSONSerialization.data(withJSONObject: env),
              let sealed = try? ChaChaPoly.seal(plain, using: relayKey).combined else { return nil }
        var r = URLRequest(url: url, timeoutInterval: timeout + 5)
        r.httpMethod = "POST"; r.httpBody = sealed
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let box = try? ChaChaPoly.SealedBox(combined: d), let open = try? ChaChaPoly.open(box, using: relayKey),
              let j = try? JSONSerialization.jsonObject(with: open) as? [String: Any], let s = j["s"] as? Int else { return nil }
        let out = (j["b"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        return (s, (j["h"] as? [String: String]) ?? [:], out)
    }

    /// Versão síncrona (para o SessionHub, que corre fora do main actor).
    static func requestSync(_ method: String, _ path: String, body: Data? = nil, timeout: Double) -> (Int, [String: String], Data)? {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var out: (Int, [String: String], Data)?
        Task.detached { out = await request(method, path, body: body, timeout: timeout); sem.signal() }
        sem.wait(); return out
    }

    /// Vivo? (60 s guardado; falha guardada 20 s para não atrasar ditados).
    static func isUp() async -> Bool {
        guard configured else { return false }
        if Date() < upUntil { return true }
        if Date() < downUntil { return false }
        let ok = await request("GET", "/health", timeout: 4)?.0 == 200
        if ok { upUntil = Date().addingTimeInterval(60) } else { downUntil = Date().addingTimeInterval(20) }
        return ok
    }
    static func markDown() { upUntil = .distantPast; downUntil = Date().addingTimeInterval(20) }
    /// PC novo (outro QR): esquece o que se sabia do anterior.
    static func reset() { lanUntil = .distantPast; lanDownUntil = .distantPast; upUntil = .distantPast; downUntil = .distantPast }

    static func transcribe(_ samples: [Float], prompt: String) async -> String? {
        guard await isUp() else { return nil }
        let p = prompt.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: " ,.-"))) ?? ""
        guard let (s, _, d) = await request("POST", "/stt", headers: ["X-Prompt": p], body: samples.withUnsafeBufferPointer { Data(buffer: $0) },
                                            timeout: max(8, Double(samples.count) / 16000 / 2)), s == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = j["text"] as? String else { markDown(); return nil }
        UserDefaults.standard.set("PC \(j["secs"] ?? "?")s", forKey: "fala.sttRoute")
        return t
    }

    /// Ditado do iPhone com destino PC: o PC mete no clipboard e faz Ctrl+V na janela ativa (e Enter, se `enter`).
    static func paste(_ text: String, enter: Bool = false) async -> Bool {
        guard let (s, _, d) = await request("POST", "/paste", headers: enter ? ["X-Enter": "1"] : [:], body: Data(text.utf8), timeout: 6), s == 200,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        return j["ok"] as? Bool == true
    }

    /// Ecrã do PC ao vivo (pc-node/screen.py): ligação direta na rede de casa, mesma porta do HTTP.
    static var screenEndpoints: [NWEndpoint] {
        guard let lan = lanBase?.dropFirst(7), let i = lan.lastIndex(of: ":"), let port = NWEndpoint.Port(String(lan[lan.index(after: i)...])) else { return [] }
        return [.hostPort(host: NWEndpoint.Host(String(lan[..<i])), port: port)]
    }
    /// Sem vídeo direto (fora de casa): imagem do ecrã pelo relay, e rato/teclas um a um.
    static func screenshot() async -> Data? {
        guard let (s, _, d) = await request("GET", "/screen", timeout: 12), s == 200, !d.isEmpty else { return nil }
        return d
    }
    @discardableResult static func input(_ j: [String: Any]) async -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: j) else { return false }
        return await request("POST", "/input", body: body, timeout: 4)?.0 == 200
    }

    /// PCM Int16 + taxa, ou nil (usa a voz do Mac).
    static func speak(_ text: String, voice: String = "") async -> (Data, Int)? {
        guard await isUp() else { return nil }
        guard let (s, h, d) = await request("POST", "/tts", headers: voice.isEmpty ? [:] : ["X-Voice": voice], body: Data(text.utf8), timeout: 30), s == 200,
              let rate = Int(h.first { $0.key.lowercased() == "x-rate" }?.value ?? "") else { markDown(); return nil }
        return (d, rate)
    }
}

// MARK: - Sessões do PC (Claude Code / Codex no Windows) juntas às do Mac. Ids com "pc:".
extension PCNode {
    nonisolated(unsafe) private static var cache: (Date, [Jarvis.Session]) = (.distantPast, [])

    /// Sessões do PC (cache 5 s; PC fora = lista vazia, sem atrasar a do Mac).
    static func sessions() -> [Jarvis.Session] {
        guard configured else { return [] }
        if Date().timeIntervalSince(cache.0) < 5 { return cache.1 }
        let list = requestSync("GET", "/sessions", timeout: 3).flatMap { $0.0 == 200 ? try? Jarvis.decoder.decode([Jarvis.Session].self, from: $0.2) : nil } ?? []
        let out = list.map { s -> Jarvis.Session in
            var s = s; s.id = "pc:" + s.id; s.cwd = s.cwd.replacingOccurrences(of: "\\", with: "/"); return s
        }
        cache = (Date(), out); return out
    }

    static func messages(_ id: String, limit: Int) -> [Jarvis.Message] {
        let raw = String(id.dropFirst(3)).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-"))) ?? ""
        return requestSync("GET", "/tail?id=\(raw)&limit=\(limit)", timeout: 6).flatMap { $0.0 == 200 ? try? Jarvis.decoder.decode([Jarvis.Message].self, from: $0.2) : nil } ?? []
    }

    /// nil = enviado; senão o erro em pt.
    static func send(_ id: String, text: String) -> String? { post("/send", id, text, timeout: 35) }

    /// Modo de permissões de uma sessão Claude do PC (Shift+Tab na consola dela).
    static func setMode(_ id: String, _ mode: String) -> String? { post("/mode", id, mode, timeout: 15) }

    /// Imagem que um agente do PC viu (caminho Windows, "C:/..."): o PC só dá pastas permitidas.
    static func file(_ path: String) -> Data? {
        let q = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~/:"))) ?? ""
        return requestSync("GET", "/file?path=" + q, timeout: 30).flatMap { $0.0 == 200 ? $0.2 : nil }
    }

    private static func post(_ path: String, _ id: String, _ text: String, timeout: Double) -> String? {
        let body = try? JSONSerialization.data(withJSONObject: ["id": String(id.dropFirst(3)), "text": text])
        guard let (_, _, d) = requestSync("POST", path, body: body, timeout: timeout),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "O PC não respondeu" }
        return (j["ok"] as? Bool) == true ? nil : (j["error"] as? String ?? "Falhou no PC")
    }
}
