import Foundation
import Network
import CryptoKit
import AppKit

/// Uma chamada com uma sessão: o iPhone manda o microfone sem parar, o Mac decide as vezes (VAD),
/// transcreve com o Whisper, injeta o prompt na sessão, espera a resposta do agente, resume em 2 a 3 frases
/// e fala-as com a voz do Jarvis. Se o Fran falar por cima, a voz pára logo (barge-in).
/// Registo das chamadas: ~/Library/Logs/Fala/call.log (o que chega, o que se ouviu, o que se disse).
enum CallLog {
    static let url: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fala")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("call.log")
    }()
    static func w(_ s: String) {
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}

final class CallServer: @unchecked Sendable {
    private var micFrames = 0, micPeak: Float = 0, lastMicLog = Date()
    static var active: [ObjectIdentifier: CallServer] = [:]
    static let activeLock = NSLock()

    let conn: NWConnection
    let sessionID: String              // a 1.ª sessão (quem atendeu)
    private var sessionIDs: [String]   // chamada de grupo: o iPhone junta mais sessões a meio ({"add": id})
    let key: SymmetricKey
    private let q = DispatchQueue(label: "fala.callserver")
    private var opener: CallFrame.Opener
    private var seq: UInt64 = 0
    private var vad = EnergyVAD()
    private var utterance: [Float] = []
    private var preroll: [Float] = []
    private var speaking = false
    /// O Mac manda a voz mais depressa do que ela toca: o iPhone ainda está a falar até esta hora.
    private var playEnd = Date.distantPast
    private var busyTurn = false
    /// Frases ditas com pausas pelo meio juntam-se numa só mensagem (0,9 s de silêncio = acabaste; o VAD já espera um pouco no fim da fala).
    private var pending: [Float] = []
    private var spoke = false          // houve fala tua em `heard` (senão é só o eco da voz do Jarvis)
    private var heard: [Float] = []    // tudo desde a última vez enviada (máx. 60 s): rede para quando o VAD falha
    private var flushGen = 0
    /// Pedidos à espera da resposta do agente. Enquanto houver, o que disseres a mais vai para a mesma tarefa
    /// (como o Dots: entra na caixa de entrada e o agente junta-o no passo seguinte), sem nova espera nem resposta repetida.
    private var waiting = 0
    private var lastSummary = ""
    private var ended = false
    private let hub: SessionHub
    private let transcribe: ([Float]) async -> String
    /// Para testes: tempo máximo à espera do agente.
    var agentTimeout: Double = 600

    init(conn: NWConnection, sessionID: String, key: SymmetricKey, hub: SessionHub = .shared,
         transcribe: @escaping ([Float]) async -> String) {
        self.conn = conn; self.sessionID = sessionID; self.sessionIDs = [sessionID]; self.key = key; self.hub = hub; self.transcribe = transcribe
        opener = CallFrame.Opener(key: key, dir: CallFrame.up)
    }

    func start(carry: Data = Data()) {
        CallLog.w("chamada aberta: sessão \(sessionID)")
        Self.activeLock.lock(); Self.active[ObjectIdentifier(self)] = self; Self.activeLock.unlock()
        JarvisVoice.shared.warmUp()
        let name = hub.list().first { $0.id == sessionID }?.name ?? "a sessão"
        event("ready", text: "Ligado a \(name)", rate: JarvisVoice.shared.sampleRate)
        // Fala logo ao atender: quem liga e não ouve nada acha que a chamada caiu.
        let last = hub.messages(sessionID, limit: 6).last { $0.role == "agent" }.map { SpokenSummary.make($0.text, maxSentences: 2, maxWords: 40) } ?? ""
        let st0 = hub.status(sessionID) ?? "idle"; let busy = st0 != "idle" && !Jarvis.Session.needsYou(st0)
        let hi: String = Me.firstName.isEmpty ? "Olá!" : "Olá \(Me.firstName)!"
        let hello = hi + " Estou na \(name)." + (busy ? " Está a trabalhar a todo o gás." : "") + (last.isEmpty ? "" : " Última coisa: " + last) + " Diz, que eu trato."
        lastSummary = last
        Task.detached { [weak self] in self?.say(hello) }
        var buf = carry
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, complete, err in
                guard let self else { return }
                if let d { buf.append(d) }
                self.q.async {
                    while true {
                        switch self.opener.next(&buf) {
                        case .incomplete: break
                        case .bad: self.end(); return
                        case .frame(let k, let p): self.handle(k, p); continue
                        }
                        break
                    }
                    if complete || err != nil { self.end(); return }
                    if !self.ended { read() }
                }
            }
        }
        read()
        // Avisos da sessão (terminou sozinha / precisa de aprovação) enquanto a chamada está aberta e sem turno.
    }

    private func handle(_ k: CallFrame.Kind, _ p: Data) {
        switch k {
        case .mic: mic(CallFrame.floats(p))
        case .hangup: end()
        case .event:
            // iPhone -> Mac: {"add": sessionID} junta outra sessão à chamada.
            // {"switch": id} troca de sessão sem desligar (fica só essa).
            if let j = (try? JSONSerialization.jsonObject(with: p)) as? [String: String], let id = j["switch"] {
                sessionIDs = [id]
                CallLog.w("chamada: troca para \(id)")
                let name = hub.list().first { $0.id == id }?.name ?? "outra sessão"
                let st = hub.status(id) ?? "idle"
                Task.detached { [weak self] in self?.say("Estás na \(name)." + (st != "idle" && !Jarvis.Session.needsYou(st) ? " Está a trabalhar." : "") + " Diz.") }
            }
            // {"diag": "..."}: o iPhone diz o que está mesmo a tocar (nível de saída, rota) para o registo.
            if let j = (try? JSONSerialization.jsonObject(with: p)) as? [String: String], let d = j["diag"] { CallLog.w("iphone: \(d)") }
            if let j = (try? JSONSerialization.jsonObject(with: p)) as? [String: String], let id = j["add"], !sessionIDs.contains(id) {
                sessionIDs.append(id)
                let name = hub.list().first { $0.id == id }?.name ?? "outra sessão"
                CallLog.w("chamada de grupo: + \(id)")
                Task.detached { [weak self] in self?.say("Juntei a \(name). Diz o nome da sessão para falares só com ela.") }
            }
        default: break
        }
    }

    private func mic(_ s: [Float]) {
        micFrames += 1; micPeak = max(micPeak, s.map { abs($0) }.max() ?? 0)
        if Date().timeIntervalSince(lastMicLog) > 2 { CallLog.w("mic: \(micFrames) blocos, pico \(String(format: "%.3f", micPeak)), a falar=\(vad.speaking)"); lastMicLog = Date(); micPeak = 0 }
        heard = Array((heard + s).suffix(16000 * 60))
        let events = vad.feed(s)
        if vad.speaking || events.contains(where: { if case .speechEnd = $0 { true } else { false } }) { utterance += s }
        else { preroll = Array((preroll + s).suffix(4800)) } // 300 ms antes do início
        for e in events {
            switch e {
            case .speechStart:
                utterance = preroll + utterance; preroll = []; spoke = true
                flushGen += 1 // continuas a falar: ainda não envia
                if speaking || Date() < playEnd { bargeIn() }
                event("listening")
            case .speechEnd:
                let u = utterance; utterance = []
                if u.count > 16000 * 4 / 10 { pending += u; scheduleFlush(after: 0.9) } // menos de 0,4 s = ruído
            }
        }
    }

    private func scheduleFlush(after s: Double) {
        flushGen += 1; let g = flushGen
        q.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self, self.flushGen == g, !self.vad.speaking, !self.pending.isEmpty else { return }
            let a = self.pending; self.pending = []; self.heard = []; self.spoke = false; self.turn(a)
        }
    }

    private func bargeIn() {
        speaking = false; playEnd = .distantPast
        JarvisVoice.shared.cancel()
        send(.stop, Data())
    }

    private func turn(_ audio: [Float]) {
        if busyTurn { pending = audio + pending; scheduleFlush(after: 0.8); return } // ainda a transcrever a anterior: junta
        busyTurn = true
        Task.detached { [self] in
            // Só a transcrição bloqueia: enquanto o agente trabalha continuas a falar (cada frase segue para a sessão).
            let t0 = Date()
            let text = await transcribe(audio).trimmingCharacters(in: .whitespacesAndNewlines)
            q.async { self.busyTurn = false }
            CallLog.w("vez: \(audio.count / 16) ms (transcrito em \(Int(Date().timeIntervalSince(t0) * 1000)) ms) -> \"\(text)\"")
            guard !text.isEmpty else { return }
            if NoiseGuard.isNoise(text, seconds: Double(audio.count) / 16000) { CallLog.w("ruído ignorado: \"\(text)\""); return }
            event("heard", text: text)
            let low = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
            if ["repete", "repete isso", "podes repetir"].contains(low) { say(lastSummary.nonEmpty ?? "Ainda não há nada para repetir."); return }
            if Self.wantsScreen(low) {
                say("Já te mostro.")
                if let img = await RemoteScreen.snapshot(width: 1280, quality: 0.6) { event("image", text: "Ecrã do Mac", image: img) }
                else { say("Não consegui tirar a captura. Falta a permissão de Gravação de Ecrã.") }
                return
            }
            if ["desliga", "adeus", "termina a chamada"].contains(low) { say("Até já."); q.asyncAfter(deadline: .now() + 2) { self.send(.hangup, Data()); self.end() }; return }
            let targets = route(text)
            event("thinking")
            if q.sync(execute: { waiting }) > 0 { // já há uma tarefa a correr: junta-lhe isto
                for sid in targets { _ = hub.send(sid, text: text) }
                say("Junto isso.")
                return
            }
            q.sync { waiting += 1 }
            defer { q.sync { waiting -= 1 } }
            // Responde logo: com Apple Intelligence uma frase a confirmar o pedido; senão uma frase fixa.
            let who = targets.map { self.name(of: $0) }.joined(separator: " e ")
            Task.detached { [weak self] in
                let a = await VoiceFront.ack(text, session: who)
                self?.say(a ?? Self.acks.randomElement()!)
            }
            // Várias sessões: todas trabalham ao mesmo tempo; as respostas dizem-se uma a uma, com o nome.
            let answers = await withTaskGroup(of: (Int, String).self) { g in
                for (i, sid) in targets.enumerated() { g.addTask { (i, await self.ask(sid, text)) } }
                var out: [(Int, String)] = []
                for await r in g { out.append(r) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let summary = targets.count == 1 ? answers[0]
                : zip(targets, answers).map { "\(self.name(of: $0)): \($1)" }.joined(separator: " ")
            lastSummary = summary
            say(summary)
        }
    }

    static let acks = ["Mandei. Já te digo.", "Ok, está a tratar disso.", "Feito o pedido, já te conto."]

    /// Manda o pedido a uma sessão e devolve o resumo falado da resposta.
    private func ask(_ sid: String, _ text: String) async -> String {
        let sent = Date()
        let before = hub.messages(sid, limit: 4).last { $0.role == "agent" }?.id
        if let e = hub.send(sid, text: text) { return e.description }
        let reply = await waitForAgent(sid, after: sent, previous: before)
        for (i, img) in Self.images(in: reply ?? "").enumerated() { event("image", text: "Imagem \(i + 1)", image: img) }
        if let reply, let nice = await VoiceFront.spoken(reply, session: name(of: sid)) { return nice }
        return reply.map { SpokenSummary.make($0) }?.nonEmpty ?? (reply == nil ? "Precisa de ti no Mac." : "Feito, já está.")
    }

    private func name(of sid: String) -> String { hub.list().first { $0.id == sid }?.name ?? "Sessão" }

    /// Com várias sessões: se a frase começa pelo nome de uma ("Kalori, ..."), vai só para essa; senão vai para todas.
    private func route(_ text: String) -> [String] {
        let ids = q.sync { sessionIDs }
        guard ids.count > 1 else { return ids }
        let low = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        for sid in ids {
            let words = name(of: sid).lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
            if let w = words.first, low.hasPrefix(w) || low.contains(w + ",") { return [sid] }
        }
        return ids
    }

    /// Espera o agente: ficar ocupado e voltar a livre, com uma resposta nova. nil = precisa de aprovação.
    private func waitForAgent(_ sid: String, after: Date, previous: String?) async -> String? {
        let deadline = Date().addingTimeInterval(agentTimeout)
        var sawBusy = false, warned = false
        var pending: (id: String, since: Date)?
        // Silêncio longo ao telefone parece chamada caída: de ~12 em 12 s diz o que a sessão está a fazer, se mudou.
        var lastNarr = Date(), lastDoing = ""
        while Date() < deadline, !ended {
            try? await Task.sleep(for: .milliseconds(500))
            let st = hub.status(sid) ?? "idle"
            if st != "idle", Date().timeIntervalSince(lastNarr) > 12, !q.sync(execute: { speaking }),
               let d = hub.list().first(where: { $0.id == sid })?.doing, d != lastDoing {
                lastDoing = d; lastNarr = Date(); say(d + ".")
            }
            if Jarvis.Session.needsYou(st) {
                if !warned { warned = true; say("A sessão está à espera da tua aprovação no Mac.") }
                continue
            }
            let last = hub.messages(sid, limit: 4).last { $0.role == "agent" }
            if st != "idle" {
                sawBusy = true
                // Sessões que nunca ficam livres (ex.: /goal, ciclos): resposta nova e parada há 4 s = diz-se já.
                if let last, last.id != previous, last.at > after {
                    if pending?.id != last.id { pending = (last.id, Date()) }
                    else if let p = pending, Date().timeIntervalSince(p.since) >= 4 { return last.text }
                }
                continue
            }
            if let last, last.id != previous, sawBusy || last.at > after { return last.text }
            if !sawBusy, Date().timeIntervalSince(after) > 20 { return nil }
        }
        return nil
    }

    private func say(_ text: String) {
        let t0 = Date(); var first = true
        q.sync { speaking = true }
        event("speaking", text: text)
        let ok = JarvisVoice.shared.speak(text) { [weak self] pcm in
            guard let self else { return }
            if first { first = false; CallLog.w("1.º áudio em \(Int(Date().timeIntervalSince(t0) * 1000)) ms") }
            var i = 0
            while i < pcm.count {
                let end = min(pcm.count, i + 8820) // ~200 ms a 22 kHz
                self.q.sync {
                    guard self.speaking else { return }
                    self.send(.tts, pcm.subdata(in: i..<end))
                    let secs = Double(end - i) / 2 / Double(JarvisVoice.shared.sampleRate)
                    self.playEnd = max(self.playEnd, Date()).addingTimeInterval(secs)
                }
                i = end
            }
        }
        CallLog.w("disse (\(ok ? "ok" : "FALHOU")): \(text.prefix(80))")
        if !ok { event("error", text: "Voz indisponível no Mac") }
        q.sync { speaking = false }
        event("listening")
    }

    /// "mostra-me o ecrã", "manda um print", "quero ver".
    static func wantsScreen(_ low: String) -> Bool {
        let l = low.folding(options: .diacriticInsensitive, locale: nil)
        return ["mostra o ecra", "mostra-me o ecra", "mostra me o ecra", "manda um print", "manda print", "tira um print", "quero ver o ecra", "mostra-me o que", "mostra o que esta"].contains { l.contains($0) }
    }

    /// Imagens que o agente referiu na resposta (caminhos .png/.jpg que existem), reduzidas para a chamada. Máx. 3.
    static func images(in text: String) -> [Data] {
        let re = try! NSRegularExpression(pattern: #"(~?/[^\s'"`()<>\]\[]+\.(?:png|jpe?g|heic|webp))"#, options: .caseInsensitive)
        let ns = text as NSString
        var seen = Set<String>(), out: [Data] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where out.count < 3 {
            let p = (ns.substring(with: m.range(at: 1)) as NSString).expandingTildeInPath
            guard seen.insert(p).inserted, let img = NSImage(contentsOfFile: p), let jpg = img.jpeg(maxWidth: 1280) else { continue }
            out.append(jpg)
        }
        return out
    }

    private func event(_ state: String, text: String? = nil, rate: Int? = nil, image: Data? = nil) {
        let d = (try? JSONEncoder().encode(CallEvent(state: state, text: text, ttsRate: rate, image: image?.base64EncodedString()))) ?? Data()
        q.async { self.send(.event, d) }
    }

    /// Só na fila `q`.
    private func send(_ k: CallFrame.Kind, _ p: Data) {
        guard !ended else { return }
        seq += 1
        conn.send(content: CallFrame.seal(k, p, dir: CallFrame.down, seq: seq, key: key), completion: .contentProcessed { _ in })
    }

    private func end() {
        guard !ended else { return }
        CallLog.w("chamada terminada")
        ended = true
        // Desligaste a meio (ou o fim da frase não foi detetado): o que ficou por enviar segue na mesma para a sessão.
        let rest = heard; heard = []; pending = []; utterance = []
        if spoke, rest.count > 16000 * 4 / 10 {
            Task.detached { [self] in
                let text = await transcribe(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                CallLog.w("ao desligar: \(rest.count / 16) ms -> \"\(text)\"")
                if !text.isEmpty { for sid in route(text) { _ = hub.send(sid, text: text) } }
            }
        }
        JarvisVoice.shared.cancel()
        conn.cancel()
        Self.activeLock.lock(); Self.active[ObjectIdentifier(self)] = nil; Self.activeLock.unlock()
    }
}

extension NSImage {
    func jpeg(maxWidth: CGFloat, quality: CGFloat = 0.7) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let k = min(1, maxWidth / CGFloat(cg.width)), w = Int(CGFloat(cg.width) * k), h = Int(CGFloat(cg.height) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high; ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let r = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: r).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
