#if os(iOS)
import Foundation
import Network

/// Teclado <-> app sem App Group (exige conta paga): a app, ligada em segundo plano, serve o estado por TCP em 127.0.0.1.
/// O pasteboard com nome não chegava à extensão (testado: o teclado lia sempre vazio).
/// Protocolo: o teclado manda uma palavra ("state", "start", "stop", "cancel", "ack") e recebe o estado em JSON.
enum KeyboardBridge {
    struct State: Codable { var phase: String; var text: String; var level: Float; var session: Bool; var at: Double }
    // phase: "idle" | "listening" | "processing" | "done" | "error"
    static let off = State(phase: "idle", text: "", level: 0, session: false, at: 0)
    private static let port: NWEndpoint.Port = 47911

    // MARK: app
    nonisolated(unsafe) static var current = off
    nonisolated(unsafe) private static var listener: NWListener?

    /// Corre na app: cada comando (exceto "state") vai para `handle` na fila principal, e a resposta é o estado depois disso.
    static func serve(_ handle: @escaping (String) -> Void) {
        guard listener == nil else { return }
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port) // ponytail: só loopback, nada sai do iPhone
        guard let l = try? NWListener(using: p) else { return }
        l.newConnectionHandler = { c in
            c.start(queue: .main)
            c.receive(minimumIncompleteLength: 1, maximumLength: 64) { d, _, _, _ in
                let cmd = d.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if cmd != "state" { handle(cmd) }
                c.send(content: try? JSONEncoder().encode(current), completion: .contentProcessed { _ in c.cancel() })
            }
        }
        l.stateUpdateHandler = { if case .failed = $0 { listener?.cancel(); listener = nil } }
        l.start(queue: .main); listener = l
    }

    // MARK: teclado
    /// Pergunta à app; nil = app desligada ou suspensa (1 s de limite).
    static func ask(_ cmd: String, _ done: @escaping (State?) -> Void) {
        let c = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        var finished = false, buf = Data()
        let finish = { (s: State?) in if !finished { finished = true; c.cancel(); done(s) } }
        c.stateUpdateHandler = { st in
            switch st { case .failed, .waiting: finish(nil); default: break }
        }
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, complete, err in
                if let d { buf += d }
                if complete || err != nil { finish(try? JSONDecoder().decode(State.self, from: buf)) } else { read() }
            }
        }
        c.start(queue: .main)
        c.send(content: Data((cmd + "\n").utf8), completion: .contentProcessed { _ in })
        read()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(nil) }
    }
}
#endif
