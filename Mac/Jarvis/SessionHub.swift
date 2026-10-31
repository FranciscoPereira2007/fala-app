import Foundation
import Darwin

/// Vê as sessões Claude Code e Codex que correm neste Mac e manda-lhes prompts.
/// - Claude: `~/.claude/sessions/<pid>.json` (registo vivo) + transcript JSONL em `~/.claude/projects`.
///   Enviar = escrever no separador do iTerm2 com o tty do processo (API Python do iTerm2; AppleScript de reserva).
/// - Codex: rollouts em `~/.codex/sessions/AAAA/MM/DD/*.jsonl` + nomes em `session_index.jsonl`.
///   Enviar = `codex queue --thread <id> --message`.
/// Tudo em leitura tolerante: formatos internos podem mudar, uma linha estranha é ignorada.
final class SessionHub: @unchecked Sendable {
    static let shared = SessionHub()
    let home: URL
    private let lock = NSLock()
    private var transcriptCache: [String: URL] = [:]
    private var lastStatus: [String: String] = [:]
    private var events: [Jarvis.Event] = []
    private var eventSeq = 0
    private var timer: DispatchSourceTimer?
    /// Chamado (fila de fundo) quando há evento novo: o Mac mostra notificação; a chamada aberta fala-o.
    var onEvent: ((Jarvis.Event) -> Void)?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    // MARK: Lista

    func list() -> [Jarvis.Session] {
        (claudeSessions() + codexThreads() + PCNode.sessions()).filter { !$0.cwd.hasSuffix("Fala/Jarvis") } // as do Jarvis são dele
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func claudeSessions() -> [Jarvis.Session] {
        let dir = home.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { u -> Jarvis.Session? in
            guard let d = try? Data(contentsOf: u), let j = Self.firstJSON(d),
                  let pid = j["pid"] as? Int, let sid = j["sessionId"] as? String, kill(pid_t(pid), 0) == 0 else { return nil }
            if let k = j["kind"] as? String, k != "interactive" { return nil }
            let cwd = j["cwd"] as? String ?? ""
            let upd = (j["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date.distantPast
            // Mesmo nome que a app do Claude: título dado pelo Fran (/rename), senão o título automático.
            let name = claudeTitle(sid) ?? (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent
            let msgs = claudeMessages(sid, limit: 6), last = msgs.last { $0.role == "agent" }
            let mode = claudeMode(sid)
            return Jarvis.Session(id: sid, kind: .claude, name: name, cwd: cwd, status: Self.liveStatus(j["status"] as? String ?? "idle", claudeTranscript(sid)),
                                  updatedAt: upd, pid: pid, lastReply: last.map { SpokenSummary.make($0.text, maxSentences: 1, maxWords: 24) },
                                  canSend: Self.tty(pid) != nil, mode: mode.current, tool: msgs.last.flatMap { $0.role == "tool" ? $0.text : nil })
        }
    }

    /// O estado vem do ficheiro da sessão, que o Claude pode deixar de atualizar (ex. disco cheio): transcript a mexer há < 20 s = a trabalhar.
    static func liveStatus(_ st: String, _ transcript: URL?) -> String {
        guard st != "busy", let t = transcript, let m = (try? t.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(m) < 20 else { return st }
        return "busy"
    }

    /// Modo de permissões: o último "permissionMode" do transcript, ou o que mudámos pelo iPhone desde então.
    nonisolated(unsafe) static var modeOverride: [String: (target: String, base: String)] = [:]
    func claudeMode(_ sid: String) -> (current: String, bypass: Bool) {
        guard let u = claudeTranscript(sid) else { return ("default", false) }
        let tail = Self.readTail(u, bytes: 256 << 10)
        let base = tail.components(separatedBy: "\"permissionMode\":\"").last.flatMap { $0.split(separator: "\"").first.map(String.init) } ?? "default"
        let bypass = tail.contains("bypassPermissions")
        lock.lock(); defer { lock.unlock() }
        if let o = Self.modeOverride[sid] { if o.base == base { return (o.target, bypass) }; Self.modeOverride[sid] = nil }
        return (base, bypass)
    }

    /// Muda o modo carregando Shift+Tab no terminal as vezes precisas (o Claude não tem comando para isto).
    func setMode(_ id: String, _ target: String) -> SendError? {
        if id.hasPrefix("pc:") { return PCNode.setMode(id, target).map { .failed($0) } }
        guard let s = claudeSessions().first(where: { $0.id == id }), let pid = s.pid, let tty = Self.tty(pid) else { return .noTerminal }
        let (cur, bypass) = claudeMode(id)
        let cycle = ["default", "acceptEdits", "plan"] + (bypass || target == "bypassPermissions" ? ["bypassPermissions"] : [])
        guard let a = cycle.firstIndex(of: cur), let b = cycle.firstIndex(of: target) else { return .failed("Modo desconhecido") }
        let n = (b - a + cycle.count) % cycle.count
        if n > 0, let e = ITerm.keys(tty: tty, escape: "[Z", times: n) { return e }
        lock.lock(); Self.modeOverride[id] = nil; lock.unlock()
        let base = claudeMode(id).current // o que o transcript diz (sem a nossa mudança)
        lock.lock(); Self.modeOverride[id] = (target, base); lock.unlock()
        return nil
    }

    /// O ficheiro pode ter lixo depois do JSON (ex. "}}"): lê só o primeiro objeto.
    static func firstJSON(_ d: Data) -> [String: Any]? {
        if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
        var depth = 0, inStr = false, esc = false
        for (i, b) in d.enumerated() {
            if inStr { if esc { esc = false } else if b == 0x5C { esc = true } else if b == 0x22 { inStr = false }; continue }
            if b == 0x22 { inStr = true } else if b == 0x7B { depth += 1 } else if b == 0x7D { depth -= 1; if depth == 0 { return try? JSONSerialization.jsonObject(with: d.prefix(i + 1)) as? [String: Any] } }
        }
        return nil
    }

    func codexThreads(maxAge: TimeInterval = 12 * 3600) -> [Jarvis.Session] {
        let names = codexNames()
        return recentRollouts(maxAge: maxAge).compactMap { u, mod in
            guard let meta = Self.readHead(u).flatMap({ Self.firstJSON(Data($0.utf8)) }),
                  let p = meta["payload"] as? [String: Any], let id = p["id"] as? String else { return nil }
            if (p["thread_source"] as? String).map({ $0 != "user" }) ?? false { return nil } // subagentes
            let cwd = p["cwd"] as? String ?? ""
            let (msgs, busy) = codexParse(u, limit: 6), tool = msgs.last.flatMap { $0.role == "tool" ? $0 : nil }
            let status = busy && Date().timeIntervalSince(mod) < 600 ? "busy" : "idle"
            let last = msgs.last { $0.role == "agent" }
            return Jarvis.Session(id: id, kind: .codex, name: names[id].flatMap { $0.count > 1 ? $0 : nil } ?? Self.folderName(cwd, fallback: "Codex"), cwd: cwd, status: status,
                                  updatedAt: mod, pid: nil, lastReply: last.map { SpokenSummary.make($0.text, maxSentences: 1, maxWords: 24) }, canSend: true,
                                  tool: tool?.text)
        }
    }

    private func recentRollouts(maxAge: TimeInterval) -> [(URL, Date)] {
        let base = home.appendingPathComponent(".codex/sessions")
        let cal = Calendar.current
        var out: [(URL, Date)] = []
        for back in 0...1 {
            let day = cal.date(byAdding: .day, value: -back, to: Date())!
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = base.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where u.pathExtension == "jsonl" {
                let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if Date().timeIntervalSince(mod) < maxAge { out.append((u, mod)) }
            }
        }
        return out
    }

    private func codexNames() -> [String: String] {
        let u = home.appendingPathComponent(".codex/session_index.jsonl")
        var names: [String: String] = [:]
        for l in Self.readTail(u, bytes: 256 << 10).split(separator: "\n") {
            guard let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                  let id = j["id"] as? String, let n = j["thread_name"] as? String else { continue }
            names[id] = n
        }
        return names
    }

    // MARK: Mensagens

    func messages(_ id: String, limit: Int = 30) -> [Jarvis.Message] {
        if id.hasPrefix("pc:") { return PCNode.messages(id, limit: limit) }
        if let u = codexURL(id) { return codexParse(u, limit: limit).0 }
        return claudeMessages(id, limit: limit)
    }

    func claudeTranscript(_ sid: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let u = transcriptCache[sid], FileManager.default.fileExists(atPath: u.path) { return u }
        let base = home.appendingPathComponent(".claude/projects")
        for d in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
            let u = d.appendingPathComponent(sid + ".jsonl")
            if FileManager.default.fileExists(atPath: u.path) { transcriptCache[sid] = u; return u }
        }
        return nil
    }

    /// Último "custom-title" (ganha) ou "ai-title" do transcript. ponytail: só os últimos 2 MB; título mais antigo que isso cai no nome derivado.
    func claudeTitle(_ sid: String) -> String? {
        guard let u = claudeTranscript(sid) else { return nil }
        var custom: String?, ai: String?
        for l in Self.readTail(u, bytes: 2 << 20).split(separator: "\n") where l.contains("-title\"") {
            guard let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] else { continue }
            if let t = j["customTitle"] as? String, !t.isEmpty { custom = t }
            if let t = j["aiTitle"] as? String, !t.isEmpty { ai = t }
        }
        return custom ?? ai
    }

    func claudeMessages(_ sid: String, limit: Int) -> [Jarvis.Message] {
        guard let u = claudeTranscript(sid) else { return [] }
        var out: [Jarvis.Message] = []
        for l in Self.readTail(u, bytes: 768 << 10).split(separator: "\n") {
            guard let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                  let type = j["type"] as? String, type == "user" || type == "assistant",
                  (j["isSidechain"] as? Bool) != true, (j["isMeta"] as? Bool) != true,
                  let m = j["message"] as? [String: Any] else { continue }
            var text = ""
            if let s = m["content"] as? String { text = s }
            else if let arr = m["content"] as? [[String: Any]] {
                text = arr.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                // Capturas que o agente viu (browser, ecrã): vêm em base64 no resultado da ferramenta. Guarda-as para o iPhone as mostrar.
                if type == "user" {
                    for (i, r) in arr.enumerated() where r["type"] as? String == "tool_result" {
                        for (k, c) in ((r["content"] as? [[String: Any]]) ?? []).enumerated() where c["type"] as? String == "image" {
                            guard let src = c["source"] as? [String: Any], let b64 = src["data"] as? String else { continue }
                            let ext = (src["media_type"] as? String ?? "").contains("png") ? "png" : "jpg"
                            let dir = home.appendingPathComponent("Pictures/Fala/shots"), f = dir.appendingPathComponent("\(j["uuid"] as? String ?? "x")-\(i)-\(k).\(ext)")
                            if !FileManager.default.fileExists(atPath: f.path), let d = Data(base64Encoded: b64) {
                                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try? d.write(to: f)
                            }
                            if let prev = out.last?.text, prev.hasPrefix("Read · /"), ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((prev as NSString).pathExtension.lowercased()) { continue } // a mesma foto que acabou de abrir
                            out.append(.init(id: f.lastPathComponent, role: "tool", text: "Image · " + f.path, at: (j["timestamp"] as? String).flatMap(Self.iso) ?? Date()))
                        }
                    }
                }
                // Ferramentas em tempo real (como no iTerm): "Bash · git status", "Edit · Sessions.swift".
                if type == "assistant" {
                    for (i, t) in arr.enumerated() where t["type"] as? String == "tool_use" {
                        let inp = t["input"] as? [String: Any] ?? [:]
                        let name = inp["description"] is String && inp["command"] != nil ? "Desc" : t["name"] as? String ?? "Ferramenta"
                        let arg = (name == "Desc" ? inp["description"] : inp["command"] ?? inp["file_path"] ?? inp["pattern"] ?? inp["description"] ?? inp["url"] ?? inp["prompt"]) as? String ?? ""
                        let img = name == "Read" && ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((arg as NSString).pathExtension.lowercased())
                        let short = img ? arg : (arg as NSString).lastPathComponent.count < arg.count && inp["file_path"] != nil ? (arg as NSString).lastPathComponent : String(arg.prefix(160)) // imagem: caminho todo (o iPhone mostra-a)
                        out.append(.init(id: (j["uuid"] as? String ?? UUID().uuidString) + "-t\(i)", role: "tool", text: name + " · " + short,
                                         at: (j["timestamp"] as? String).flatMap(Self.iso) ?? Date()))
                    }
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || (type == "user" && (text.hasPrefix("<") || text.hasPrefix("Caveat:"))) { continue }
            let at = (j["timestamp"] as? String).flatMap(Self.iso) ?? Date()
            out.append(.init(id: j["uuid"] as? String ?? UUID().uuidString, role: type == "user" ? "user" : "agent", text: text, at: at))
        }
        return Array(out.suffix(limit))
    }

    private func codexURL(_ id: String) -> URL? {
        recentRollouts(maxAge: 7 * 86400).first { $0.0.lastPathComponent.contains(id) }?.0
    }

    /// Mensagens úteis + se o último turno ainda não terminou.
    func codexParse(_ u: URL, limit: Int) -> ([Jarvis.Message], Bool) {
        var out: [Jarvis.Message] = [], busy = false
        for l in Self.readTail(u, bytes: 1 << 20).split(separator: "\n") {
            guard let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                  let p = j["payload"] as? [String: Any], let pt = p["type"] as? String else { continue }
            let type = j["type"] as? String
            if type == "event_msg", pt == "task_started" { busy = true }
            if type == "event_msg", pt == "task_complete" || pt == "turn_aborted" { busy = false }
            if type == "response_item", pt == "function_call" || pt == "custom_tool_call", let name = p["name"] as? String { // ferramenta do Codex
                let a = (p["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let cmd = (a?["cmd"] as? String) ?? (a?["command"] as? [String])?.last ?? ""
                out.append(.init(id: p["call_id"] as? String ?? UUID().uuidString, role: "tool", text: name + (cmd.isEmpty ? "" : " · " + cmd), at: Date()))
                continue
            }
            guard type == "response_item", pt == "message", let role = p["role"] as? String, role == "user" || role == "assistant",
                  let content = p["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || (role == "user" && text.hasPrefix("<")) { continue }
            let at = (j["timestamp"] as? String).flatMap(Self.iso) ?? Date()
            out.append(.init(id: p["id"] as? String ?? UUID().uuidString, role: role == "user" ? "user" : "agent", text: text, at: at))
        }
        return (Array(out.suffix(limit)), busy)
    }

    // MARK: Enviar

    enum SendError: Error, CustomStringConvertible {
        case notFound, needsYou, noTerminal, failed(String)
        var description: String {
            switch self {
            case .notFound: "Sessão não encontrada"
            case .needsYou: "A sessão está à espera de aprovação no Mac. Responde lá primeiro."
            case .noTerminal: "Não encontrei o separador do iTerm desta sessão"
            case .failed(let s): s
            }
        }
    }

    func send(_ id: String, text: String) -> SendError? {
        // Sem caracteres de controlo: um \r escondido carregava no Enter a meio (aprovações, várias mensagens).
        let t = String(String.UnicodeScalarView(text.replacingOccurrences(of: "\n", with: " ").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })).trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return .failed("Texto vazio") }
        if id.hasPrefix("pc:") { return PCNode.send(id, text: t).map { .failed($0) } }
        if let s = claudeSessions().first(where: { $0.id == id }) {
            if s.needsYou { return .needsYou }
            guard let pid = s.pid, let tty = Self.tty(pid) else { return .noTerminal }
            return ITerm.send(tty: tty, text: t)
        }
        if codexURL(id) != nil {
            let r = Self.run(Self.which("codex") ?? "/opt/homebrew/bin/codex", ["queue", "--thread", id, "--message", t], timeout: 20)
            return r.status == 0 ? nil : .failed("codex queue falhou: " + r.out.suffix(160))
        }
        return .notFound
    }

    /// Esc na sessão (pára o que o agente está a fazer, como no terminal). Só Claude no iTerm.
    func interrupt(_ id: String) -> SendError? {
        guard let s = claudeSessions().first(where: { $0.id == id }) else { return codexURL(id) != nil ? .failed("O Codex não se interrompe daqui") : .notFound }
        guard let pid = s.pid, let tty = Self.tty(pid) else { return .noTerminal }
        return ITerm.keys(tty: tty, escape: "", times: 1)
    }

    /// Fecha uma sessão Claude (/exit no separador). Pede-se sempre confirmação ao Fran antes (regra do Jarvis).
    func close(_ id: String) -> SendError? {
        if let e = interrupt(id), claudeSessions().contains(where: { $0.id == id }) { return e }
        Thread.sleep(forTimeInterval: 0.4)
        return send(id, text: "/exit")
    }

    // MARK: Eventos (terminou / precisa de ti)

    func startWatching(interval: Double = 2) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume(); timer = t
    }

    func poll() {
        let now = list()
        lock.lock()
        let prev = lastStatus
        lastStatus = Dictionary(now.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()
        guard !prev.isEmpty else { return } // 1.ª volta: só memoriza
        for s in now {
            guard let was = prev[s.id], was != s.status else { continue }
            if was == "busy", s.status == "idle" {
                let last = messages(s.id, limit: 4).last { $0.role == "agent" }
                emit(.finished, s, SpokenSummary.make(last?.text ?? "") .nonEmpty ?? "Terminou.")
            } else if s.needsYou {
                emit(.needsYou, s, "Precisa da tua aprovação no Mac.")
            }
        }
    }

    private func emit(_ k: Jarvis.Event.Kind, _ s: Jarvis.Session, _ summary: String) {
        lock.lock()
        eventSeq += 1
        let e = Jarvis.Event(id: eventSeq, kind: k, sessionID: s.id, sessionName: s.name, summary: summary, at: Date())
        events.append(e); if events.count > 50 { events.removeFirst(events.count - 50) }
        lock.unlock()
        onEvent?(e)
    }

    func events(since: Int) -> ([Jarvis.Event], Int) {
        lock.lock(); defer { lock.unlock() }
        return (events.filter { $0.id > since }, eventSeq)
    }

    func status(_ id: String) -> String? { list().first { $0.id == id }?.status }

    // MARK: Pedidos do iPhone

    func handle(_ req: Jarvis.Request) -> Jarvis.Response {
        switch req.op {
        case "list": return .init(ok: true, sessions: list(), lastEvent: events(since: .max).1)
        case "tail": return .init(ok: true, messages: messages(req.id ?? "", limit: req.limit ?? 30))
        case "send":
            var text = req.text ?? ""
            if let d = req.file {
                let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Fala")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = (req.fileName ?? "anexo").replacingOccurrences(of: "/", with: "-")
                let url = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(name)")
                do { try d.write(to: url) } catch { return .init(ok: false, error: "Não guardei o anexo: \(error.localizedDescription)") }
                text = (text.isEmpty ? "Vê este ficheiro:" : text) + " " + url.path
            }
            if let e = send(req.id ?? "", text: text) { return .init(ok: false, error: e.description) }
            return .init(ok: true)
        case "mode": // modo de permissões de uma sessão Claude (text = default | acceptEdits | plan | bypassPermissions)
            if let e = setMode(req.id ?? "", req.text ?? "") { return .init(ok: false, error: e.description) }
            return .init(ok: true)
        case "file":
            // Imagem de uma sessão do PC ("C:/..."): vem do PC, que valida as pastas.
            if let p = req.text, p.range(of: "^[A-Za-z]:/", options: .regularExpression) != nil {
                guard let d = PCNode.file(p) else { return .init(ok: false, error: "Ficheiro indisponível") }
                return .init(ok: true, file: d)
            }
            // Só ficheiros de imagem/vídeo dentro da pasta do utilizador, até 25 MB.
            let real = realpath(req.text ?? "", nil).map { p in defer { free(p) }; return String(cString: p) } ?? "" // segue symlinks ANTES de validar (resolvingSymlinksInPath tirava o /private de /private/tmp e falhava a lista)
            let h = NSHomeDirectory()
            // ponytail: toda a home (os agentes guardam capturas em pastas escondidas, ex. ~/.claude), menos Library e chaves; só imagem/vídeo.
            let allowed = [h + "/", "/private/tmp/", "/private/var/folders/"], blocked = ["/Library/", "/.ssh/", "/.gnupg/"].map { h + $0 }
            let ext = (real as NSString).pathExtension.lowercased()
            guard allowed.contains(where: real.hasPrefix), !blocked.contains(where: real.hasPrefix), ["png", "jpg", "jpeg", "gif", "webp", "heic", "mp4", "mov"].contains(ext) else { return .init(ok: false, error: "Pasta não permitida: " + (real.isEmpty ? "não existe" : real)) }
            guard let a = try? FileManager.default.attributesOfItem(atPath: real), (a[.size] as? Int ?? 0) < 25 << 20 else { return .init(ok: false, error: "Ficheiro grande demais (máx. 25 MB)") }
            guard let d = FileManager.default.contents(atPath: real) else { return .init(ok: false, error: "Sem acesso ao ficheiro (\(errno))") }
            return .init(ok: true, file: d)
        case "commands": return .init(ok: true, commands: Self.slashCommands())
        case "accounts": return .init(ok: true, accounts: AIAccounts.status())
        case "dot": // o teu Jarvis (agente sempre disponível, como o Dot): devolve o id; a resposta vem por "dotResult"
            return .init(ok: true, job: JarvisAgent.start(req.text ?? ""))
        case "dotConfig": // definições do Jarvis: text vazio = ler; JSON = gravar
            if let t = req.text, !t.isEmpty { JarvisAgent.configSet(t) }
            return .init(ok: true, reply: JarvisAgent.configJSON())
        case "dotResult":
            let r = JarvisAgent.result(req.id ?? "")
            return .init(ok: r.error == nil, error: r.error, reply: r.reply, done: r.done, progress: r.progress)
        case "login": // do iPhone: abre o login do Claude/ChatGPT no Mac (acaba-se no browser, pelo ecrã remoto)
            guard let k = req.id, AIAccounts.kinds.contains(k) else { return .init(ok: false, error: "Conta desconhecida") }
            AIAccounts.login(k); return .init(ok: true)
        case "events":
            let (ev, last) = events(since: req.since ?? 0)
            return .init(ok: true, events: ev, lastEvent: last)
        default: return .init(ok: false, error: "Operação desconhecida")
        }
    }

    // MARK: Utilitários

    static func folderName(_ cwd: String, fallback: String) -> String {
        let n = (cwd as NSString).lastPathComponent
        return n.isEmpty || n == "." || n == "/" ? fallback : n
    }

    static func tty(_ pid: Int) -> String? {
        let r = run("/bin/ps", ["-o", "tty=", "-p", String(pid)], timeout: 3)
        let t = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("?") ? nil : "/dev/" + t
    }

    /// Tudo o que o "/" do Claude Code mostra: comandos base, skills (pessoais e de plugins), comandos .md e MCPs.
    static func slashCommands() -> [String] {
        let fm = FileManager.default, h = NSHomeDirectory()
        var out: [String: String] = [:]
        for (n, d) in [("clear", "Limpa a conversa"), ("compact", "Compacta o contexto"), ("model", "Muda o modelo"), ("effort", "Muda o effort"),
                       ("rename", "Muda o nome da sessão"), ("resume", "Retoma outra sessão"), ("cost", "Custo da sessão"), ("context", "Uso do contexto"),
                       ("mcp", "Servidores MCP"), ("agents", "Subagentes"), ("review", "Revê o código"), ("init", "Cria o CLAUDE.md"), ("help", "Ajuda")] { out[n] = d }
        func desc(_ f: String) -> String {
            guard let t = try? String(contentsOfFile: f, encoding: .utf8) else { return "" }
            for l in t.split(separator: "\n").prefix(15) where l.hasPrefix("description:") {
                return String(l.dropFirst(12)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).prefix(90).description
            }
            return ""
        }
        var skillDirs = [h + "/.claude/skills"]
        if let e = fm.enumerator(atPath: h + "/.claude/plugins/cache") {
            while let p = e.nextObject() as? String { if p.hasSuffix("/skills"), p.split(separator: "/").count <= 5 { skillDirs.append(h + "/.claude/plugins/cache/" + p) } }
        }
        for d in skillDirs { for n in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where out[n] == nil && !n.hasPrefix(".") { out[n] = desc(d + "/" + n + "/SKILL.md") } }
        for f in (try? fm.contentsOfDirectory(atPath: h + "/.claude/commands")) ?? [] where f.hasSuffix(".md") { out[String(f.dropLast(3))] = desc(h + "/.claude/commands/" + f) }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: h + "/.claude.json")), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let m = j["mcpServers"] as? [String: Any] { for k in m.keys { out["mcp:" + k] = "Servidor MCP" } }
        return out.keys.sorted().map { ($0.hasPrefix("mcp:") ? "" : "/") + $0 + "\t" + (out[$0] ?? "") }
    }

    static func which(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", NSHomeDirectory() + "/.local/bin/"].map { $0 + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func readTail(_ u: URL, bytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: u) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        var s = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) } // 1.ª linha cortada
        return s
    }

    static func readHead(_ u: URL, bytes: Int = 64 << 10) -> String? {
        guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? h.close() }
        let s = String(decoding: h.readData(ofLength: bytes), as: UTF8.self)
        return s.split(separator: "\n").first.map(String.init)
    }

    static func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    @discardableResult
    static func run(_ bin: String, _ args: [String], stdin: String? = nil, timeout: Double = 10) -> (status: Int32, out: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        let inPipe = Pipe(); if stdin != nil { p.standardInput = inPipe }
        guard (try? p.run()) != nil else { return (-1, "não arrancou: " + bin) }
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)); try? inPipe.fileHandleForWriting.close() }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension String { var nonEmpty: String? { isEmpty ? nil : self } }

/// Escreve num separador do iTerm2 identificado pelo tty.
/// 1.º API Python do iTerm2 (venv em Application Support/Fala/jarvis-venv com o pacote `iterm2`),
/// 2.º AppleScript (`write text`). O texto vai numa linha e o Enter vai separado (o TUI do Claude trata o
/// texto colado como um bloco e só submete com o Enter).
enum ITerm {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Fala")
    static var python: URL { support.appendingPathComponent("jarvis-venv/bin/python3") }

    static let script = """
    import asyncio, sys
    import iterm2
    TTY, TEXT = sys.argv[1], sys.stdin.read()
    async def main(conn):
        app = await iterm2.async_get_app(conn)
        for w in app.terminal_windows:
            for t in w.tabs:
                for s in t.sessions:
                    if await s.async_get_variable("tty") == TTY:
                        await s.async_send_text(TEXT)
                        await asyncio.sleep(0.25)
                        await s.async_send_text("\\r")
                        print("ok"); return
        print("notfound")
    iterm2.run_until_complete(main)
    """

    /// Teclas especiais (ESC + seq, ex.: "[Z" = Shift+Tab) sem Enter.
    static func keys(tty: String, escape seq: String, times: Int) -> SessionHub.SendError? {
        let osa = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  repeat \(times) times
                    tell s to write text ((character id 27) & "\(seq)") newline no
                    delay 0.2
                  end repeat
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "notfound"
        end tell
        """
        let r = SessionHub.run("/usr/bin/osascript", ["-e", osa], timeout: 15)
        return r.out.contains("ok") ? nil : .noTerminal
    }

    static func send(tty: String, text: String) -> SessionHub.SendError? {
        if FileManager.default.isExecutableFile(atPath: python.path) {
            let s = support.appendingPathComponent("iterm_send.py")
            try? script.write(to: s, atomically: true, encoding: .utf8)
            let r = SessionHub.run(python.path, [s.path, tty], stdin: text, timeout: 15)
            if r.out.contains("ok") { return nil }
            if r.out.contains("notfound") { return .noTerminal }
        }
        // AppleScript de reserva.
        let esc = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let osa = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  tell s to write text "\(esc)" newline no
                  delay 0.25
                  tell s to write text ""
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "notfound"
        end tell
        """
        let r = SessionHub.run("/usr/bin/osascript", ["-e", osa], timeout: 15)
        if r.out.contains("ok") { return nil }
        return r.out.contains("notfound") ? .noTerminal : .failed("iTerm não respondeu: " + r.out.suffix(160))
    }
}
