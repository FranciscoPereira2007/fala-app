import Foundation
import Network

/// Túnel pelo relay (de qualquer rede, sem VPN): liga uma ligação TCP local a um WebSocket do relay e passa os bytes
/// nos dois sentidos. O conteúdo já vai cifrado ponta a ponta (CallFrame), o relay só vê bytes.
/// - iPhone: ouve em 127.0.0.1 e cada ligação abre /r/<sala>/live; o ecrã ao vivo e a chamada veem um endereço local normal.
/// - Mac: quando o relay manda "live:<sid>", abre /r/<sala>/live/<sid> (com a prova) e liga-o à própria porta.
enum RelayTunnel {
    nonisolated(unsafe) static var log: (String) -> Void = { _ in } // Mac: CallLog
    static func url(_ path: String) -> URL? {
        URL(string: LinkCrypto.relayBase.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") + path)
    }

    /// Passa bytes até um dos lados fechar. Cada envio espera pelo anterior: a fila nunca cresce.
    static func pump(_ c: NWConnection, _ ws: URLSessionWebSocketTask) {
        let done = Once()
        func end(_ why: String) { guard done.first() else { return }; log("túnel fechou: \(why)"); c.cancel(); ws.cancel(with: .normalClosure, reason: nil) }
        func down() { // local -> relay
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, complete, err in
                if let d, !d.isEmpty {
                    ws.send(.data(d)) { e in if let e { end("relay \(e)") } else if complete { end("local fechou") } else { down() } }
                } else if complete || err != nil { end("local \(err.map { "\($0)" } ?? "fechou")") } else { down() }
            }
        }
        func up() { // relay -> local
            ws.receive { r in
                guard case .success(let m) = r else { if case .failure(let e) = r { end("relay \(e)") }; return }
                guard case .data(let d) = m else { up(); return }
                c.send(content: d, completion: .contentProcessed { e in if let e { end("local \(e)") } else { up() } })
            }
        }
        c.stateUpdateHandler = { if case .failed(let e) = $0 { end("local \(e)") } else if case .cancelled = $0 { end("local cancelada") } }
        c.start(queue: q)
        ws.maximumMessageSize = 8 << 20
        ws.resume()
        down(); up()
    }

    private static let q = DispatchQueue(label: "fala.tunnel")
    nonisolated(unsafe) private static var listeners: [String: NWListener] = [:]

    /// iPhone: endereço local que leva à sala `room` pelo relay (um ouvinte por sala, reaproveitado).
    static func endpoint(room: String) async -> NWEndpoint? {
        if let l = q.sync(execute: { listeners[room] }), let p = l.port { return .hostPort(host: "127.0.0.1", port: p) }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params), let u = url("/r/" + room + "/live") else { return nil }
        l.newConnectionHandler = { c in pump(c, URLSession.shared.webSocketTask(with: u)) }
        return await withCheckedContinuation { cont in
            let once = Once()
            l.stateUpdateHandler = { st in
                switch st {
                case .ready: if once.first() { listeners[room] = l; cont.resume(returning: l.port.map { .hostPort(host: "127.0.0.1", port: $0) }) }
                case .failed, .cancelled: q.async { listeners[room] = nil }; if once.first() { cont.resume(returning: nil) }
                default: break
                }
            }
            l.start(queue: q)
        }
    }

    /// Mac/PC: o iPhone pediu o túnel `sid`; liga-o à porta local `port` onde a Fala já ouve.
    static func host(room: String, sid: String, proof: String, port: UInt16) {
        guard sid.count == 32, sid.allSatisfy(\.isHexDigit), let u = url("/r/" + room + "/live/" + sid), let p = NWEndpoint.Port(rawValue: port) else { return }
        var rq = URLRequest(url: u); rq.setValue(proof, forHTTPHeaderField: "X-Mac-Proof")
        log("túnel \(sid.prefix(6)) -> porta \(port)")
        pump(NWConnection(host: "127.0.0.1", port: p, using: .tcp), URLSession.shared.webSocketTask(with: rq))
    }

    /// Verdadeiro só na 1.ª chamada (fechar uma vez, responder uma vez).
    final class Once: @unchecked Sendable {
        private var used = false
        private let lock = NSLock()
        func first() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }
}
