import Foundation
import Network
import CryptoKit

/// iPhone <-> Mac. Em casa: Bonjour (_fala._tcp). Fora: endereço guardado (Tailscale), porta 47800.
///
/// Protocolo (uma ligação por mensagem, o cliente fecha o envio):
/// - v2 (atual): tudo cifrado com o código (Shared/LinkCrypto.swift). Corpos dentro da cifra:
///   "P" ping -> "P" + nome do Mac; áudio "A"/"a"/"H" + "0"/"1" + "C" (AAC .m4a) ou "R" (PCM) -> "T"+texto;
///   "H" = só histórico (envio atrasado da fila, não cola). "B" = ocupado com o mesmo pedido, repetir.
/// - v1 (iPhones antigos): "K" + código + "\n" em claro, corpos abaixo. Sem o código o Mac responde "N".
/// - Texto: "0"/"1" (Enter) + texto UTF-8. Resposta "ok".
/// - Áudio: "A" (colar) ou "a" (teste, não cola) + "0"/"1" (Enter) + PCM Int16 LE 16 kHz mono.
///   O Mac transcreve com Whisper e responde "T" + texto final UTF-8 (ou "E" se falhar).
enum Link {
    /// Resumo curto de uma imagem do ecrã remoto ("não mudou" sem reenviar).
    static func digest(_ d: Data) -> String { SHA256.hash(data: d).prefix(8).map { String(format: "%02x", $0) }.joined() }
    static let type = "_fala._tcp"
    static let port: UInt16 = 47800

    static func newToken() -> String {
        let a = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        // 26 símbolos de 31 = ~128 bits: o código é a chave da cifra e da sala do relay (auditoria: 10 era fraco offline).
        var g = SystemRandomNumberGenerator()
        return String((0..<26).map { _ in a.randomElement(using: &g)! })
    }

    static func withToken(_ token: String, _ body: Data) -> Data { Data(("K" + token + "\n").utf8) + body }

    static func splitToken(_ d: Data) -> (String, Data)? {
        guard d.first == 0x4B, let nl = d.firstIndex(of: 0x0A), nl - d.startIndex <= 64 else { return nil }
        return (String(decoding: d[(d.startIndex + 1)..<nl], as: UTF8.self), Data(d[(nl + 1)...]))
    }

    /// Comparação em tempo constante.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func encodeAudio(_ s: [Float], paste: Bool, enter: Bool) -> Data {
        var d = Data([paste ? 0x41 : 0x61, enter ? 0x31 : 0x30])
        d.reserveCapacity(2 + s.count * 2)
        let ints = s.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        ints.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// v2: modo ("A" cola, "a" teste, "H" só histórico) + Enter + "C" AAC comprimido (fallback "R" PCM).
    static func encodeAudioV2(_ s: [Float], mode: UInt8, enter: Bool, compressed: Data? = nil) -> Data {
        if let c = compressed ?? AudioCodec.encodeAAC(s) { return Data([mode, enter ? 0x31 : 0x30, 0x43]) + c }
        var d = encodeAudio(s, paste: true, enter: enter); d[d.startIndex] = mode
        d.insert(0x52, at: d.startIndex + 2); return d
    }

    /// Descodifica um corpo de áudio v2 (3 bytes de cabeçalho) para 16 kHz mono.
    static func decodeAudioV2(_ d: Data) -> [Float] {
        guard d.count > 3 else { return [] }
        let kind = d[d.startIndex + 2], payload = Data(d.dropFirst(3))
        if kind == 0x43 { return AudioCodec.decode(payload) ?? [] }
        return decodeAudio(Data([0, 0]) + payload)
    }

    static func decodeAudio(_ d: Data) -> [Float] {
        let body = Data(d.dropFirst(2))
        var out = [Float](repeating: 0, count: body.count / 2)
        body.withUnsafeBytes { raw in
            for i in 0..<out.count { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32767 }
        }
        return out
    }
}

