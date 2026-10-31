import Foundation
import CryptoKit

/// Protocolo v2: cifra ponta a ponta com o código de emparelhamento.
///
/// Chave = HKDF-SHA256(código, sal "fala-link-v2"). Cada pedido vai num ChaCha20-Poly1305:
///   fio:    "F2" + tamanho(UInt32 BE) + nonce(12) + cifra + tag(16)  (tamanho: o Mac sabe quando acabou sem fechar o envio)
///   claro:  id(16 aleatórios) + hora(Int64 ms, BE) + corpo
/// A resposta vai cifrada com a mesma chave e começa pelo id do pedido (liga resposta a pedido).
/// Anti-replay: o Mac recusa pedidos com mais de 10 min de diferença de relógio e ids já vistos;
/// um id repetido dentro da janela devolve a resposta guardada (retry seguro, nunca cola 2x).
/// Mesmo num relay ou rede aberta, só quem tem o código lê ou forja mensagens.
enum LinkCrypto {
    static let magic = Data("F2".utf8)
    static let maxSkew: TimeInterval = 120 // cada tentativa leva hora nova; 2 min chegam e encurtam o replay

    static func key(_ token: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.uppercased().utf8)),
                               salt: Data("fala-link-v2".utf8), info: Data("iphone-mac".utf8), outputByteCount: 32)
    }

    static func newID() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }

    /// Pedido cifrado. `id` fixo entre tentativas para o Mac reconhecer o retry.
    static func seal(_ body: Data, id: Data, token: String, now: Date = Date()) -> Data {
        var plain = id
        withUnsafeBytes(of: Int64(now.timeIntervalSince1970 * 1000).bigEndian) { plain.append(contentsOf: $0) }
        plain.append(body)
        return frame(try! ChaChaPoly.seal(plain, using: key(token)).combined)
    }

    static func frame(_ box: Data) -> Data {
        var d = magic
        withUnsafeBytes(of: UInt32(box.count).bigEndian) { d.append(contentsOf: $0) }
        return d + box
    }

    /// Bytes que a mensagem completa ocupa (nil se ainda não chegou o cabeçalho).
    static func frameLength(_ d: Data) -> Int? {
        guard d.count >= 6, isV2(d) else { return nil }
        return 6 + Int(d.dropFirst(2).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }

    private static func box(_ d: Data) -> ChaChaPoly.SealedBox? {
        guard let n = frameLength(d), d.count == n else { return nil }
        return try? ChaChaPoly.SealedBox(combined: Data(d.dropFirst(6)))
    }

    struct Request { let id: Data; let sent: Date; let body: Data }

    /// Sala no relay (fora de casa sem VPN): hash do código, o relay nunca vê o código nem o conteúdo.
    static func room(_ token: String) -> String {
        SHA256.hash(data: Data(("fala-room-v1:" + token.uppercased()).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Relay grátis (Cloudflare Worker). "fala.relay" nas preferências sobrepõe-se (testes).
    static var relayBase: String { UserDefaults.standard.string(forKey: "fala.relay") ?? "https://fala-relay.fancy-bird-92d5.workers.dev" }

    static func isV2(_ d: Data) -> Bool { d.count >= 2 && d.prefix(2) == magic }

    /// nil = código errado ou mensagem adulterada.
    static func open(_ d: Data, token: String) -> Request? {
        guard let b = box(d), let p = try? ChaChaPoly.open(b, using: key(token)), p.count >= 24 else { return nil }
        let ms = p.dropFirst(16).prefix(8).reduce(Int64(0)) { $0 << 8 | Int64($1) }
        return Request(id: Data(p.prefix(16)), sent: Date(timeIntervalSince1970: Double(ms) / 1000), body: Data(p.dropFirst(24)))
    }

    static func sealReply(_ body: Data, id: Data, token: String) -> Data {
        frame(try! ChaChaPoly.seal(id + body, using: key(token)).combined)
    }

    static func openReply(_ d: Data, id: Data, token: String) -> Data? {
        guard let b = box(d), let p = try? ChaChaPoly.open(b, using: key(token)), p.prefix(16) == id else { return nil }
        return Data(p.dropFirst(16))
    }
}

/// Lado Mac: janela anti-replay + cache das respostas (retry devolve a mesma resposta).
final class ReplayGuard {
    enum Verdict { case fresh, duplicate(Data?), stale }
    private var seen: [Data: (at: Date, reply: Data?)] = [:]
    private let lock = NSLock()

    func check(_ r: LinkCrypto.Request, now: Date = Date()) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        seen = seen.filter { now.timeIntervalSince($0.value.at) < LinkCrypto.maxSkew * 2 }
        if abs(now.timeIntervalSince(r.sent)) > LinkCrypto.maxSkew { return .stale }
        if let s = seen[r.id] { return .duplicate(s.reply) }
        seen[r.id] = (now, nil)
        return .fresh
    }

    func store(_ id: Data, reply: Data) { lock.lock(); seen[id]?.reply = reply; lock.unlock() }
}
