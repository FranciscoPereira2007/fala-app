import Foundation

/// O teu Jarvis (como o Dot do ChatGPT): um agente sempre disponível neste Mac, numa pasta só dele (~/Fala/Jarvis)
/// com memória em ficheiros. Corre com a conta da própria pessoa: Codex (ChatGPT, também no plano grátis) ou
/// Claude Code. Cada pedido continua a mesma conversa. Igual ao pc-node/jarvis.py do Windows.
/// Do iPhone: op "dot" (texto -> id do pedido) e "dotResult" (id -> resposta), porque um pedido pode levar minutos.
enum JarvisAgent {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Fala/Jarvis")
    private static let stateURL = home.appendingPathComponent(".fala-jarvis.json")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var jobs: [String: (done: Bool, reply: String?, error: String?, at: Date, progress: [String])] = [:]
    nonisolated(unsafe) private static var currentJob: String? // a fila é série: um pedido de cada vez
    /// Mensagens intermédias do agente ("Vou ver os teus emails.") para o iPhone ir dizendo enquanto trabalha.
    private static func progress(_ t: String) { lock.withLock { if let id = currentJob { jobs[id]?.progress.append(t) } } }
    private static let q = DispatchQueue(label: "fala.jarvis.agent") // um pedido de cada vez: é uma só conversa

    static var guide: String { let n = Me.firstName.isEmpty ? "a pessoa" : Me.firstName; return """
    # Jarvis

    És o Jarvis da Fala: o assistente pessoal de \(n), neste Mac. Como o Dot do ChatGPT: um agente sempre
    disponível que faz o trabalho no computador e manda nas outras sessões de IA.

    - Falas português de Portugal, direto e curto. As respostas são lidas em voz alta: no máximo 3 frases,
      sem listas, sem código, sem URLs, sem travessões. Se fizeste trabalho, diz o resultado e o próximo passo.
    - A tua pasta é esta. Guarda o que aprendes sobre \(n) em memoria.md (preferências, nomes, projetos) e
      lê-a no início de cada pedido. Coisas que fazes muitas vezes ficam em skills/<nome>.md.
    - Pede confirmação antes de apagar, pagar, enviar mensagens ou emails em nome de \(n).
    - Estás numa conversa por voz: se o pedido dá trabalho, a tua PRIMEIRA mensagem é uma frase curta a dizer o que
      vais fazer ("Vou ver os teus emails."), antes de usares ferramentas. Ela é dita logo em voz alta.

    ## As outras sessões (Claude Code e Codex deste Mac)

    \(n) pode dizer "diz à sessão da loja para...", "o que está a fazer o Codex do site?" ou "cria uma sessão
    nova para...". Usa a API local da Fala. A URL e o token estão em .fala-api (1.ª e 2.ª linha):

        A=$(sed -n 1p .fala-api); T=$(sed -n 2p .fala-api)
        curl -s -H "X-Fala-Token: $T" "$A/sessions"                  # id, kind, name, cwd, status, lastReply
        curl -s -H "X-Fala-Token: $T" "$A/tail?id=<id>&limit=20"     # últimas mensagens
        curl -s -H "X-Fala-Token: $T" -d '{"id":"<id>","text":"..."}' "$A/send"
        curl -s -H "X-Fala-Token: $T" -d '{"cwd":"/caminho","prompt":"..."}' "$A/new"   # sessão nova (Codex)
        curl -s -H "X-Fala-Token: $T" -d '{"id":"<id>"}' "$A/interrupt"   # Esc: pára o que a sessão está a fazer
        curl -s -H "X-Fala-Token: $T" -d '{"id":"<id>"}' "$A/close"       # fecha a sessão (pede confirmação antes)
        curl -s -H "X-Fala-Token: $T" "$A/screenshot"                    # captura do ecrã -> {"path": ...}

    Comandos com barra ("/edit", "/compact", skills) mandam-se com /send, com o texto a começar por "/".
    Imagens: se tiras uma captura, geras uma imagem ou queres mostrar um ficheiro de imagem, escreve o caminho
    completo na resposta (ex.: /Users/.../ecra.jpg). Na chamada, a imagem aparece logo no ecrã do telemóvel.
    Mexer no Mac (computer use): tira a captura, olha para ela, e clica/escreve. Coordenadas de 0 a 1 na captura.
        curl -s -H "X-Fala-Token: $T" -d '{"app":"TextEdit"}' "$A/activate"                 # põe a app à frente (obrigatório antes)
        curl -s -H "X-Fala-Token: $T" -d '{"app":"TextEdit","x":0.5,"y":0.3}' "$A/click"     # "right":true, "double":true
        curl -s -H "X-Fala-Token: $T" -d '{"app":"TextEdit","t":"olá"}' "$A/type"            # escrever
        curl -s -H "X-Fala-Token: $T" -d '{"app":"TextEdit","k":"n","m":["cmd"]}' "$A/type"  # tecla com cmd/shift/opt/ctrl
    "app" é obrigatório. O /type manda as teclas só para essa app (não precisa de estar à frente). O /click só funciona
    se a app estiver à frente (a Fala recusa com 409): usa /activate; se \(n) estiver a usar o Mac, prefere AppleScript da app.
    Nunca uses osascript "activate" nem keystroke: o macOS não deixa e o texto ia para outra janela.
    Para abrir apps: open -a "Nome". Pesquisar na web: a tua pesquisa web. Imagens: gera com o que tiveres e diz o caminho.
    Depois de cada clique, tira outra captura para confirmares o resultado.

    Escolher a sessão certa (pensa, não adivinhes):
    1. Lista as sessões e, para CADA uma ativa, lê o tail (limit=8): o que \(n) lhe pediu e em que está a trabalhar.
    2. Compara com o pedido: o projeto/app de que ele fala ("a Fala", "a loja"), o assunto (voz, chamada, ecrã),
       ficheiros e pastas. A sessão certa é a que já está a trabalhar NESSE projeto, mesmo que o nome não o diga.
    3. Nunca mandes para a sessão de outro projeto só por estar ativa ou ser a mais recente.
    4. Duas igualmente boas, ou nenhuma? Pergunta qual (diz os nomes e o que cada uma está a fazer).
    Depois de mandar, espera um pouco e lê o tail para dizeres o que a sessão respondeu.
    """ }

    /// Definições escolhidas no iPhone: motor (auto/codex/claude), modelo ("" = o da conta) e acesso
    /// ("computador" = mexe em tudo, como o Dot; "pasta" = só a pasta dele).
    static let defaults: [String: String] = ["engine": "auto", "model": "", "access": "computador"]
    static func settings() -> [String: String] {
        let st = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))) as? [String: String] ?? [:]
        return defaults.merging(st.filter { defaults[$0.key] != nil }) { $1 }
    }
    static func configJSON() -> String {
        var m: [String: Any] = settings()
        let codexModels: [String] = AIAccounts.which("codex").map { exe in
            guard let j = try? JSONSerialization.jsonObject(with: Data(run(exe, ["debug", "models"], timeout: 30).utf8)) else { return [] }
            let ms = (j as? [String: Any])?["models"] as? [[String: Any]] ?? (j as? [[String: Any]]) ?? []
            return ms.filter { $0["visibility"] as? String == "list" }.compactMap { $0["slug"] as? String }
        } ?? []
        m["models"] = ["codex": codexModels, "claude": ["sonnet", "opus", "haiku"]]
        m["accounts"] = AIAccounts.status().mapValues { $0.loggedIn }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: m)) ?? Data(), as: UTF8.self)
    }
    static func configSet(_ json: String) {
        guard let c = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
        lock.withLock {
            var st = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))) as? [String: String] ?? [:]
            for k in defaults.keys { if let v = c[k] { st[k] = "\(v)" } }
            if c["model"] != nil { st["codex"] = nil; st["claude"] = nil } // modelo novo: conversa nova
            try? JSONSerialization.data(withJSONObject: st).write(to: stateURL)
        }
    }

    /// Sessão nova (Codex) numa pasta: corre em fundo e aparece na lista de sessões.
    static func newSession(cwd: String, prompt: String) -> [String: Any] {
        guard let exe = AIAccounts.which("codex") else { return ["ok": false, "error": "Codex não instalado"] }
        var dir: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: cwd, isDirectory: &dir) && dir.boolValue ? cwd : home.path
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.currentDirectoryURL = URL(fileURLWithPath: folder)
        p.arguments = ["exec", "--skip-git-repo-check", "-c", "sandbox_mode=\"\(settings()["access"] == "pasta" ? "workspace-write" : "danger-full-access")\"", prompt]
        // Lançado pela app (launchd): o PATH não tem o Homebrew e o codex (node) não arrancava sem dar erro.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fala/codex-new.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let h = try? FileHandle(forWritingTo: log)
        p.standardInput = FileHandle.nullDevice; p.standardOutput = h ?? FileHandle.nullDevice; p.standardError = h ?? FileHandle.nullDevice
        return (try? p.run()) != nil ? ["ok": true] : ["ok": false, "error": "Não arrancou"]
    }

    static func start(_ text: String) -> String {
        let id = UUID().uuidString.prefix(12).lowercased()
        lock.withLock { jobs[String(id)] = (false, nil, nil, Date(), []); jobs = jobs.filter { Date().timeIntervalSince($0.value.at) < 3600 } }
        q.async {
            lock.withLock { currentJob = String(id) }
            let (reply, err) = ask(text)
            lock.withLock { currentJob = nil; jobs[String(id)] = (true, reply, err, Date(), jobs[String(id)]?.progress ?? []) }
        }
        return String(id)
    }

    static func result(_ id: String) -> (done: Bool, reply: String?, error: String?, progress: [String]) {
        lock.withLock { jobs[id].map { ($0.done, $0.reply, $0.error, $0.progress) } ?? (true, nil, "Pedido desconhecido", []) }
    }

    /// Corre o pedido e espera pela resposta final.
    static func ask(_ text: String) -> (String?, String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return (nil, "Pedido vazio") }
        let acc = AIAccounts.status(), set = settings()
        let want = set["engine"] ?? "auto"
        let engine = (want == "codex" || want == "claude") && acc[want]?.loggedIn == true ? want
            : acc["claude"]?.loggedIn == true ? "claude" : acc["codex"]?.loggedIn == true ? "codex" : nil // auto: Claude primeiro (percebe melhor a que sessão te referes)
        guard let engine, let exe = AIAccounts.which(engine) else { return (nil, "Liga a tua conta do ChatGPT ou do Claude neste Mac (Definições, Conta).") }
        ensureHome()
        var st = (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateURL))) as? [String: String] ?? [:]
        let chosen = set["model"].flatMap { $0.isEmpty ? nil : $0 }
        let (reply, sid, model) = engine == "codex" ? codex(exe, t, st["codex"], chosen ?? st["codexModel"])
            : claude(exe, t, st["claude"], ["sonnet", "opus", "haiku"].contains(chosen ?? "") ? chosen : nil)
        if let sid { st[engine] = sid }
        if let model, chosen == nil { st["codexModel"] = model }
        try? JSONSerialization.data(withJSONObject: st).write(to: stateURL)
        return reply.isEmpty ? (nil, "O Jarvis não respondeu") : (reply, nil)
    }

    /// Ao arrancar a app: o guia (CLAUDE.md/AGENTS.md) fica logo atualizado, mesmo antes do 1.º pedido.
    static func prepare() { ensureHome() }

    private static func ensureHome() {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for f in ["AGENTS.md", "CLAUDE.md"] where (try? String(contentsOf: home.appendingPathComponent(f), encoding: .utf8)) != guide {
            try? guide.write(to: home.appendingPathComponent(f), atomically: true, encoding: .utf8) // são nossos: atualizam-se
        }
        let mem = home.appendingPathComponent("memoria.md")
        if !FileManager.default.fileExists(atPath: mem.path) { try? "# Memória\n".write(to: mem, atomically: true, encoding: .utf8) }
    }

    static func run(_ exe: String, _ args: [String], timeout: Double = 600, onLine: ((String) -> Void)? = nil) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; p.currentDirectoryURL = home
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? ""].joined(separator: ":")
        if exe.hasSuffix("codex") { env["CODEX_HOME"] = codexHome() }
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        var data = Data()
        let reader = DispatchQueue(label: "fala.jarvis.read")
        let done = DispatchSemaphore(value: 0)
        reader.async { // lê já (o pipe não enche) e linha a linha (o iPhone vai falando enquanto o agente trabalha)
            var pending = Data()
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk); pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    onLine?(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)); pending.removeSubrange(pending.startIndex...nl)
                }
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate() }
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// O Codex do Jarvis tem casa própria (só com o login da pessoa): sem as skills e MCPs dela arranca em 4 s em vez de 11.
    private static func codexHome() -> String {
        let h = home.appendingPathComponent(".codex"), auth = h.appendingPathComponent("auth.json")
        try? FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: auth)
        try? FileManager.default.copyItem(atPath: NSHomeDirectory() + "/.codex/auth.json", toPath: auth.path)
        return h.path
    }

    /// Codex: o modelo do config.toml da pessoa pode não existir na conta ChatGPT; nesse caso usa o 1.º da conta.
    private static func codex(_ exe: String, _ text: String, _ sid: String?, _ model: String?) -> (String, String?, String?) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("fala-jarvis-last.txt")
        try? FileManager.default.removeItem(at: out)
        let mode = settings()["access"] == "pasta" ? "workspace-write" : "danger-full-access"
        var opts = ["--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"\(mode)\"", "-c", "model_reasoning_effort=\"low\"", "-o", out.path] // o config.toml pode ter "max": 14 s só para dizer olá
        if let model { opts += ["-m", model] }
        let args = (sid.map { ["exec", "resume", $0] } ?? ["exec"]) + opts + [text]
        let lines = run(exe, args, onLine: { l in // {"type":"item.completed","item":{"type":"agent_message","text":"..."}}
            guard l.contains("agent_message"), let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                  j["type"] as? String == "item.completed", let it = j["item"] as? [String: Any], let t = it["text"] as? String else { return }
            progress(t)
        }).split(separator: "\n")
        var newSid = sid, failed = ""
        for l in lines {
            guard let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] else { continue }
            if let t = j["thread_id"] as? String { newSid = t }
            if j["type"] as? String == "turn.failed" { failed = String(l) }
        }
        let reply = (try? String(contentsOf: out, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reply.isEmpty, failed.contains("not supported"), model == nil, let m = accountModel(exe) { return codex(exe, text, sid, m) }
        if reply.isEmpty, sid != nil { return codex(exe, text, nil, model) } // conversa antiga apagada: começa outra
        return (reply, newSid, model)
    }

    private static func accountModel(_ exe: String) -> String? {
        guard let j = try? JSONSerialization.jsonObject(with: Data(run(exe, ["debug", "models"], timeout: 30).utf8)) else { return nil }
        let ms = (j as? [String: Any])?["models"] as? [[String: Any]] ?? (j as? [[String: Any]]) ?? []
        return ms.first { $0["visibility"] as? String == "list" }?["slug"] as? String
    }

    private static func claude(_ exe: String, _ text: String, _ sid: String?, _ model: String? = nil) -> (String, String?, String?) {
        let perm = settings()["access"] == "pasta" ? "acceptEdits" : "bypassPermissions"
        let raw = run(exe, ["-p", text, "--output-format", "json", "--permission-mode", perm] + (sid.map { ["--resume", $0] } ?? []) + ["--model", model ?? "sonnet", "--effort", model == "haiku" ? "max" : "medium", "--setting-sources", "project,local"]) // sem os hooks globais da pessoa: 16 s -> 8 s
        let j = raw.firstIndex(of: "{").flatMap { try? JSONSerialization.jsonObject(with: Data(raw[$0...].utf8)) as? [String: Any] }
        let reply = (j?["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.isEmpty, sid != nil { return claude(exe, text, nil, model) }
        return (reply, j?["session_id"] as? String ?? sid, nil)
    }
}
