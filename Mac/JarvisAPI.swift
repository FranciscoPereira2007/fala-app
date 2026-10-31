import Foundation
import AppKit
import Network

/// API local só para o teu Jarvis (127.0.0.1:47801, token em ~/Fala/Jarvis/.fala-api): ver as sessões do Claude
/// Code e do Codex deste Mac, ler, mandar mensagens e criar sessões novas. Assim o Jarvis manda nas outras
/// sessões ("diz à sessão da loja para..."), como o Dot. Nunca ouve fora do próprio Mac.
enum JarvisAPI {
    static let port: UInt16 = 47801
    nonisolated(unsafe) private static var listener: NWListener?
    static let token: String = {
        let f = JarvisAgent.home.appendingPathComponent(".fala-api")
        if let s = try? String(contentsOf: f, encoding: .utf8), let t = s.split(separator: "\n").dropFirst().first { return String(t) }
        return UUID().uuidString + UUID().uuidString
    }()

    static func start() {
        guard listener == nil else { return }
        try? FileManager.default.createDirectory(at: JarvisAgent.home, withIntermediateDirectories: true)
        JarvisAgent.prepare()
        try? "http://127.0.0.1:\(port)\n\(token)\n".write(to: JarvisAgent.home.appendingPathComponent(".fala-api"), atomically: true, encoding: .utf8)
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let l = try? NWListener(using: p) else { return }
        l.newConnectionHandler = { c in serve(c) }
        l.start(queue: .global())
        listener = l
    }

    private static func serve(_ c: NWConnection) {
        c.start(queue: .global())
        var buf = Data()
        func read() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, err in
                if let d { buf.append(d) }
                guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { if done || err != nil { c.cancel() } else { read() }; return }
                let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self)
                let len = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }.flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buf[headEnd.upperBound...]
                if body.count < len && !done { read(); return }
                let (status, out) = route(head, Data(body.prefix(len)))
                let resp = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data(resp.utf8) + out, completion: .contentProcessed { _ in c.cancel() })
            }
        }
        read()
    }

    /// "TextEdit" ou "Editor de Texto": nome mostrado, nome do .app ou bundle id.
    private static func matches(_ a: NSRunningApplication, _ n: String) -> Bool {
        [a.localizedName, a.bundleURL?.deletingPathExtension().lastPathComponent, a.bundleIdentifier].contains { $0?.caseInsensitiveCompare(n) == .orderedSame }
    }

    private static func route(_ head: String, _ body: Data) -> (String, Data) {
        let lines = head.split(separator: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return ("400 Bad Request", Data("{}".utf8)) }
        let tok = lines.first { $0.lowercased().hasPrefix("x-fala-token:") }.map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
        guard tok == token else { return ("401 Unauthorized", Data("{}".utf8)) }
        let comps = URLComponents(string: String(first[1]))
        let q = { (n: String) in comps?.queryItems?.first { $0.name == n }?.value }
        let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let hub = SessionHub.shared
        func json(_ v: Any) -> Data { (try? JSONSerialization.data(withJSONObject: v)) ?? Data("{}".utf8) }
        switch (String(first[0]), comps?.path ?? "") {
        case ("GET", "/sessions"):
            let list = hub.list().filter { !$0.cwd.hasSuffix("Fala/Jarvis") }.map { s -> [String: Any] in
                ["id": s.id, "kind": s.kind.rawValue, "name": s.name, "cwd": s.cwd, "status": s.status, "lastReply": s.lastReply ?? ""] }
            return ("200 OK", json(list))
        case ("GET", "/tail"):
            let m = hub.messages(q("id") ?? "", limit: Int(q("limit") ?? "") ?? 20).map { ["role": $0.role, "text": $0.text] }
            return ("200 OK", json(m))
        case ("POST", "/send"):
            let r = hub.handle(.init(op: "send", id: j["id"] as? String, text: j["text"] as? String))
            return ("200 OK", json(["ok": r.ok, "error": (r.error ?? "") as Any]))
        case ("POST", "/new"):
            return ("200 OK", json(JarvisAgent.newSession(cwd: j["cwd"] as? String ?? "", prompt: j["prompt"] as? String ?? "")))
        case ("POST", "/interrupt"):
            let e = hub.interrupt(j["id"] as? String ?? "")
            return ("200 OK", json(["ok": e == nil, "error": e?.description ?? ""]))
        case ("POST", "/close"):
            let e = hub.close(j["id"] as? String ?? "")
            return ("200 OK", json(["ok": e == nil, "error": e?.description ?? ""]))
        case ("GET", "/screenshot"):
            // Captura do ecrã do Mac num ficheiro: dizer o caminho na resposta mostra-a na chamada.
            let sem = DispatchSemaphore(value: 0); var img: Data?
            Task { img = await RemoteScreen.snapshot(width: 1600, quality: 0.75); sem.signal() }
            _ = sem.wait(timeout: .now() + 10)
            guard let img else { return ("200 OK", json(["ok": false, "error": "Sem permissão de Gravação de Ecrã"])) }
            let dir = JarvisAgent.home.appendingPathComponent("capturas")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("ecra-\(Int(Date().timeIntervalSince1970)).jpg")
            try? img.write(to: f)
            return ("200 OK", json(["ok": true, "path": f.path]))
        case ("POST", "/activate"):
            // Põe a app à frente a partir da Fala (o macOS recusa o "activate" pedido por processos em fundo).
            guard let name = j["app"] as? String else { return ("400 Bad Request", json(["ok": false])) }
            let ok = DispatchQueue.main.sync { () -> Bool in
                guard let a = NSWorkspace.shared.runningApplications.first(where: { matches($0, name) }) else { return false }
                NSApp.yieldActivation(to: a)
                return a.activate(options: [.activateAllWindows])
            }
            Thread.sleep(forTimeInterval: 0.6)
            let fa = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }
            return ("200 OK", json(["ok": ok && fa.map { matches($0, name) } == true, "frente": fa?.localizedName ?? ""]))
        case ("POST", "/click"):
            // x e y de 0 a 1 na última captura (mesmo ecrã: o do rato). Computer use do Jarvis.
            // Segurança: só mexe se a app pedida for a que está à frente (senão escrevia/clicava onde o Fran está a trabalhar).
            let fa = DispatchQueue.main.sync { NSWorkspace.shared.frontmostApplication }, front = fa?.localizedName ?? ""
            guard let want = j["app"] as? String, fa.map({ matches($0, want) }) == true else {
                return ("409 Conflict", json(["ok": false, "error": "A app à frente é \(front), não \(j["app"] as? String ?? "(diz a app em \"app\")"). Usa /activate primeiro.", "frente": front]))
            }
            guard let x = j["x"] as? Double, let y = j["y"] as? Double else { return ("400 Bad Request", json(["ok": false, "error": "x e y de 0 a 1"])) }
            DispatchQueue.main.sync { RemoteScreen.click(x: x, y: y, right: j["right"] as? Bool ?? false, double: j["double"] as? Bool ?? false) }
            return ("200 OK", json(["ok": true]))
        case ("POST", "/type"):
            // {"app":"TextEdit","t":"texto"} escreve; {"app":..., "k":"return","m":["cmd"]} tecla com modificadores.
            // As teclas vão direto para o processo da app: não precisa de estar à frente e nunca caem onde o Fran está.
            guard let want = j["app"] as? String,
                  let pid = DispatchQueue.main.sync(execute: { NSWorkspace.shared.runningApplications.first { matches($0, want) }?.processIdentifier })
            else { return ("404 Not Found", json(["ok": false, "error": "App não está aberta (abre com open -a)."])) }
            guard let d = try? JSONSerialization.data(withJSONObject: j.filter { $0.key != "app" }), let c = try? JSONDecoder().decode(RemoteInput.Cmd.self, from: d) else { return ("400 Bad Request", json(["ok": false])) }
            let e = DispatchQueue.main.sync { () -> String? in RemoteInput.targetPID = pid; defer { RemoteInput.targetPID = nil }; return RemoteInput.apply(c) }
            return ("200 OK", json(["ok": e == nil, "error": e ?? ""]))
        default:
            return ("404 Not Found", Data("{}".utf8))
        }
    }
}
