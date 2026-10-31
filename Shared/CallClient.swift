import Foundation
import Network
import CryptoKit

/// Lado iPhone da chamada (sem áudio: o iOS liga o microfone/altifalante, os testes no Mac usam WAVs).
/// Abre uma ligação, faz o aperto de mão cifrado ("C" + sessão) e depois manda o microfone em blocos
/// de 20 a 100 ms e recebe eventos, áudio TTS e ordens de parar (barge-in).
final class CallClient: @unchecked Sendable {
    var onEvent: ((CallEvent) -> Void)?
    var onAudio: ((Data, Int) -> Void)?     // PCM Int16, taxa
    var onStop: (() -> Void)?
    var onEnd: ((String?) -> Void)?

    private let q = DispatchQueue(label: "fala.call")
    private var conn: NWConnection?
    private var key: SymmetricKey?
    private var opener: CallFrame.Opener?
    private var seq: UInt64 = 0
    private var ttsRate = 22050
    private var ended = false

    /// Liga ao primeiro endereço que responder. Devolve nil se ficou ligado, ou a razão da falha.
    func connect(endpoints: [NWEndpoint], token: String, session: String, timeout: Double = 6) async -> String? {
        for ep in endpoints {
            if let err = await attempt(ep, token: token, session: session, timeout: timeout) {
                if err == "Código errado" { return err }
                continue
            }
            return nil
        }
        return "Mac não encontrado"
    }

    private func attempt(_ ep: NWEndpoint, token: String, session: String, timeout: Double) async -> String? {
        let id = LinkCrypto.newID()
        let hello = LinkCrypto.seal(Jarvis.encode("C", Jarvis.CallStart(session: session)), id: id, token: token)
        switch await Self.handshake(ep, hello: hello, id: id, token: token, expect: 0x43, timeout: timeout, queue: q) {
        case .failure(let e): return e == .wrongCode ? "Código errado" : e == .refused ? "O Mac recusou a chamada" : e.rawValue
        case .success(let (c, nonce, carry)):
            let k = CallFrame.key(token: token, requestID: id, nonce: nonce)
            key = k; opener = CallFrame.Opener(key: k, dir: CallFrame.down); conn = c
            readLoop(c, carry: carry)
            return nil
        }
    }

    enum HandshakeError: String, Error { case wrongCode = "Código errado", refused = "Recusado", noLink = "Sem ligação", dropped = "Ligação caiu", timeout = "Sem resposta" }

    /// Aperto de mão cifrado que deixa a ligação aberta (chamada "C", ecrã ao vivo "V"):
    /// manda `hello`, espera a resposta `expect` + nonce de 16 bytes. Devolve a ligação, o nonce e o que já chegou a mais.
    static func handshake(_ ep: NWEndpoint, hello: Data, id: Data, token: String, expect: UInt8, timeout: Double, queue q: DispatchQueue)
        async -> Result<(NWConnection, Data, Data), HandshakeError> {
        let c = NWConnection(to: ep, using: .tcp)
        return await withCheckedContinuation { cont in
            var done = false, buf = Data()
            func finish(_ r: Result<(NWConnection, Data, Data), HandshakeError>) {
                if !done { done = true; if case .failure = r { c.cancel() }; cont.resume(returning: r) }
            }
            func readHello() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, complete, err in
                    if let d { buf.append(d) }
                    if let n = LinkCrypto.frameLength(buf), buf.count >= n {
                        let frame = Data(buf.prefix(n)); buf.removeFirst(n)
                        guard let r = LinkCrypto.openReply(frame, id: id, token: token), r.first == expect, r.count == 17 else {
                            finish(.failure(LinkCrypto.openReply(frame, id: id, token: token) == nil ? .wrongCode : .refused)); return
                        }
                        finish(.success((c, Data(r.dropFirst()), buf)))
                        return
                    }
                    if buf == Data("N".utf8) || complete || err != nil { finish(.failure(buf == Data("N".utf8) ? .wrongCode : .dropped)) } else { readHello() }
                }
            }
            c.stateUpdateHandler = { st in
                switch st {
                case .ready: c.send(content: hello, completion: .contentProcessed { _ in }); readHello()
                case .failed, .waiting: finish(.failure(.noLink))
                default: break
                }
            }
            c.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) { finish(.failure(.timeout)) }
        }
    }

    private func readLoop(_ c: NWConnection, carry: Data) {
        var buf = carry
        func drain() {
            while true {
                switch opener!.next(&buf) {
                case .incomplete: return
                case .bad: end("Frame inválido"); return
                case .frame(let k, let d): handle(k, d)
                }
            }
        }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, complete, err in
                guard let self, !self.ended else { return }
                if let d { buf.append(d); drain() }
                if complete || err != nil { self.end(nil); return }
                read()
            }
        }
        q.async { drain(); read() }
    }

    private func handle(_ k: CallFrame.Kind, _ d: Data) {
        switch k {
        case .event:
            if let e = try? JSONDecoder().decode(CallEvent.self, from: d) {
                if let r = e.ttsRate { ttsRate = r }
                onEvent?(e)
            }
        case .tts: onAudio?(d, ttsRate)
        case .stop: onStop?()
        case .hangup: end(nil)
        default: break
        }
    }

    /// Microfone (16 kHz mono). Thread-safe.
    func sendMic(_ samples: [Float]) { send(.mic, CallFrame.pcm16(samples)) }

    func send(_ kind: CallFrame.Kind, _ payload: Data) {
        q.async { [self] in
            guard let c = conn, let key, !ended else { return }
            seq += 1
            c.send(content: CallFrame.seal(kind, payload, dir: CallFrame.up, seq: seq, key: key), completion: .contentProcessed { _ in })
        }
    }

    func hangup() {
        send(.hangup, Data())
        q.asyncAfter(deadline: .now() + 0.3) { [self] in end(nil) }
    }

    private func end(_ reason: String?) {
        q.async { [self] in
            guard !ended else { return }
            ended = true; conn?.cancel(); conn = nil
            onEnd?(reason)
        }
    }
}
