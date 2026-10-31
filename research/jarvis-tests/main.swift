// Testes do Jarvis: protocolo, resumo, VAD, frames da chamada, sessões reais, envio e chamada ponta a ponta.
import Foundation
import Network
import CryptoKit
import AppKit

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) { print((ok ? "OK   " : "FALHA ") + name); if !ok { failures += 1 } }

/// Mac falso com o MESMO tratamento do MacReceiver para "PJ", "J" e "C" (sem WhisperKit: transcrição injetada).
final class FakeMac: @unchecked Sendable {
    let token: String; let replay = ReplayGuard(); var listener: NWListener?
    let q = DispatchQueue(label: "fakemac")
    var transcribe: ([Float]) async -> String = { _ in "" }
    var oldMac = false
    init(token: String) { self.token = token }
    func start(port: UInt16) {
        let l = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [self] c in
            c.start(queue: q); var buf = Data()
            func read() { c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, err in
                if let d { buf.append(d) }
                let n = LinkCrypto.frameLength(buf)
                if let n, buf.count >= n { self.handle(Data(buf.prefix(n)), c) } else if done || err != nil { c.cancel() } else { read() } } }
            read()
        }
        l.start(queue: q); listener = l
    }
    func handle(_ raw: Data, _ c: NWConnection) {
        guard let req = LinkCrypto.open(raw, token: token) else { c.send(content: Data("N".utf8), isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        let send: (Data) -> Void = { b in c.send(content: LinkCrypto.sealReply(b, id: req.id, token: self.token), isComplete: true, completion: .contentProcessed { _ in c.cancel() }) }
        guard case .fresh = replay.check(req) else { send(Data("B".utf8)); return }
        let b = req.body
        switch b.first {
        case 0x50:
            let j = !oldMac && b.count > 1 && b[b.startIndex + 1] == 0x4A
            send(Data(("PFakeMac" + (j ? "\n" + Jarvis.capability : "")).utf8))
        case 0x4A where !oldMac:
            let r = Jarvis.decode(Jarvis.Request.self, b)!
            DispatchQueue.global().async { send(Jarvis.encode("J", SessionHub.shared.handle(r))) }
        case 0x43 where !oldMac:
            let cs = Jarvis.decode(Jarvis.CallStart.self, b)!
            let nonce = LinkCrypto.newID()
            c.send(content: LinkCrypto.sealReply(Data("C".utf8) + nonce, id: req.id, token: token), completion: .contentProcessed { _ in })
            let s = CallServer(conn: c, sessionID: cs.session, key: CallFrame.key(token: token, requestID: req.id, nonce: nonce), transcribe: transcribe)
            s.start()
        default: send(Data("ok".utf8)) // Mac antigo: colava como texto
        }
    }
}

func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * 16000)) }
func tone(_ s: Double) -> [Float] { (0..<Int(s * 16000)).map { Float(sin(Double($0) * 0.09)) * 0.3 } }

@main struct JarvisTests {
    @MainActor static func main() async throws {
        // Imagens na chamada: caminhos de imagem na resposta do agente viram cartões; "mostra-me o ecrã" pede captura.
        let png = NSTemporaryDirectory() + "fala-teste.png"
        let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try? bmp.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
        check(CallServer.images(in: "Tirei a captura: \(png) e o resto.").count == 1, "imagem referida na resposta")
        check(CallServer.images(in: "Ficheiro `\(png)` duas vezes \(png)").count == 1, "imagem repetida conta uma vez")
        check(CallServer.images(in: "Nada aqui, só /tmp/naoexiste.png").isEmpty, "caminho inexistente ignorado")
        check(CallServer.wantsScreen("mostra-me o ecrã"), "pede o ecrã")
        check(NoiseGuard.isNoise("Ejra, Zyra, P.", seconds: 1.2), "ruído: palavras inventadas ignoradas")
        check(NoiseGuard.isNoise("Legendas pela comunidade Amara.org", seconds: 2), "ruído: legenda fantasma ignorada")
        check(!NoiseGuard.isNoise("Sim.", seconds: 0.6) && !NoiseGuard.isNoise("repete", seconds: 0.8), "ruído: sim/repete passam")
        check(!NoiseGuard.isNoise("Muda a cor do botão para verde.", seconds: 2.5), "ruído: pedido normal passa")
        check(!CallServer.wantsScreen("muda o botão para azul"), "pedido normal não é captura")
        if let tk = UserDefaults(suiteName: "com.fran.fala.mac")?.string(forKey: "fala.token") { UserDefaults.standard.set(tk, forKey: "fala.token") }
        let args = CommandLine.arguments
        // 1. Resumo falado
        let reply = """
        Feito. Mudei `Mac/Receiver.swift` e corri os testes:

        ```swift
        let x = 1
        ```
        | a | b |
        |---|---|

        - O canal novo está em /Users/x/proj/Shared/Jarvis.swift
        A aba Sessões já lista as sessões do Claude e do Codex, e o envio pelo iTerm funcionou à primeira. Falta só testares no iPhone — e decidires a voz. Vê https://exemplo.pt para detalhes.
        """
        let sum = SpokenSummary.make(reply)
        print("     resumo: \(sum)")
        check(!sum.contains("`") && !sum.contains("/") && !sum.contains("let x") && !sum.contains("http"), "resumo: sem código, caminhos nem URLs")
        check(!sum.contains("—") && !sum.contains("–"), "resumo: sem travessões")
        // Guarda: estados como "shell" são "a trabalhar", não "precisa de ti" (a chamada recusava/avisava mal).
        check(!Jarvis.Session.needsYou("shell") && !Jarvis.Session.needsYou("busy") && Jarvis.Session.needsYou("permission"), "estado: shell/busy = a trabalhar, permission = precisa de ti")
        // Guarda: ditado ao vivo no teclado remoto corrige a frase parcial em vez de a repetir.
        var typed = " "
        for step in [" Este aqui", " Este aqui é um", " Este é um teste", " Este é um teste."] {
            let (d, t) = textDiff(typed, step); typed = String(typed.dropLast(d)) + t
        }
        check(typed == " Este é um teste.", "teclado remoto: parciais corrigidas, sem texto repetido (\(typed))")
        check(SpokenSummary.splitSentences(sum).count <= 3 && sum.split(separator: " ").count <= 46, "resumo: no máximo 3 frases curtas")
        check(sum.contains("Sessões"), "resumo: usa o último parágrafo do agente")
        // 2. VAD
        var v = EnergyVAD(); var ev: [EnergyVAD.Event] = []
        for chunk in [silence(1), tone(1.2), silence(1)] { ev += v.feed(chunk) }
        check(ev.count == 2, "VAD: 1 início + 1 fim de fala (\(ev.count) eventos)")
        var v2 = EnergyVAD(); check(v2.feed(silence(3)).isEmpty, "VAD: silêncio não dispara")
        // 3. Frames da chamada
        let tok = "K7QX2M9PAB", k = CallFrame.key(token: tok, requestID: LinkCrypto.newID(), nonce: LinkCrypto.newID())
        var buf = CallFrame.seal(.mic, Data([1, 2, 3]), dir: CallFrame.up, seq: 1, key: k) + CallFrame.seal(.mic, Data([4]), dir: CallFrame.up, seq: 2, key: k)
        var op = CallFrame.Opener(key: k, dir: CallFrame.up)
        if case .frame(_, let d) = op.next(&buf) { check(d == Data([1, 2, 3]), "chamada: frame abre") } else { check(false, "chamada: frame abre") }
        if case .frame = op.next(&buf) { check(true, "chamada: 2 frames no mesmo buffer") } else { check(false, "chamada: 2 frames") }
        var rep = CallFrame.seal(.mic, Data([9]), dir: CallFrame.up, seq: 2, key: k)
        if case .bad = op.next(&rep) { check(true, "chamada: seq repetido recusado (replay)") } else { check(false, "chamada: replay") }
        var refl = CallFrame.seal(.tts, Data([9]), dir: CallFrame.down, seq: 9, key: k)
        if case .bad = op.next(&refl) { check(true, "chamada: direção trocada recusada (reflexão)") } else { check(false, "chamada: reflexão") }
        var other = CallFrame.seal(.mic, Data([9]), dir: CallFrame.up, seq: 10, key: CallFrame.key(token: tok, requestID: LinkCrypto.newID(), nonce: LinkCrypto.newID()))
        if case .bad = op.next(&other) { check(true, "chamada: frame de outra chamada recusado") } else { check(false, "chamada: outra chamada") }
        // 4. Protocolo pelo canal cifrado (Mac falso + MacSender real)
        UserDefaults.standard.set(tok, forKey: "fala.token")
        let mac = FakeMac(token: tok); mac.start(port: 47911)
        let s = MacSender(outboxDir: FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-tests"))
        s.fixedEndpoints = [.hostPort(host: "127.0.0.1", port: 47911)]
        mac.oldMac = true
        check(await s.probeJarvis() == false, "compat: Mac antigo não tem Jarvis (iPhone não envia J)")
        check(await s.jarvis(.init(op: "list")) == nil, "compat: sem Jarvis, pedido J nem sai")
        mac.oldMac = false
        check(await s.probeJarvis(), "compat: Mac novo anuncia o Jarvis no ping PJ")
        check(await s.ping() == "FakeMac", "compat: ping antigo continua igual")
        let t0 = Date()
        let list = await s.jarvis(.init(op: "list"))
        check(list?.ok == true, "lista: \(list?.sessions?.count ?? -1) sessões em \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        for x in (list?.sessions ?? []).prefix(8) { print("     \(x.kind.rawValue) · \(x.name) · \(x.folder) · \(x.status)\(x.canSend ? "" : " · sem terminal") · \(x.lastReply ?? "")") }
        if let first = list?.sessions?.first(where: { $0.lastReply?.isEmpty == false }) {
            let tail = await s.jarvis(.init(op: "tail", id: first.id, limit: 5))
            check((tail?.messages?.count ?? 0) > 0, "mensagens: \(tail?.messages?.count ?? 0) da sessão \(first.name)")
            // Esta própria sessão do Claude Code (tem ferramentas e título automático).
            let me = SessionHub.shared.claudeMessages("4c485919-a510-4e96-bb26-3f18a5111f60", limit: 60)
            check(me.contains { $0.role == "tool" && $0.text.contains(" · ") }, "tempo real: ferramentas aparecem (\(me.filter { $0.role == "tool" }.count) em 60)")
            check(SessionHub.shared.claudeTitle("4c485919-a510-4e96-bb26-3f18a5111f60") != nil, "nome: igual à app do Claude (\(SessionHub.shared.claudeTitle("4c485919-a510-4e96-bb26-3f18a5111f60") ?? "-"))")
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Fala")
            let before = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
            let att = SessionHub.shared.handle(.init(op: "send", id: "nao-existe", text: "teste", fileName: "teste.txt", file: Data("ola".utf8)))
            let after = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
            check(after == before + 1 && att.ok == false, "anexo: guardado em ~/Downloads/Fala antes de enviar")

        }
        let ev2 = await s.jarvis(.init(op: "events", since: 0))
        check(ev2?.ok == true, "eventos: responde")
        // 4b. Lista do "/" e chamada SEM mexer na sessão: cumprimento falado + "repete" (não injeta prompt).
        let cmds = await s.jarvis(.init(op: "commands"), timeout: 10)
        let cl = cmds?.commands ?? []
        check(cl.count > 50 && cl.contains { $0.hasPrefix("/edit\t") } && cl.contains { $0.hasPrefix("mcp:rea") }, "lista do /: \(cl.count) comandos, skills e MCPs (inclui /edit e mcp:rea)")
        if let sid = SessionHub.shared.list().first?.id {
            mac.transcribe = { _ in "repete" }
            let cc = CallClient()
            var audio = 0, states: [String] = []
            cc.onEvent = { e in states.append(e.state) }
            cc.onAudio = { d, _ in audio += d.count }
            let err = await cc.connect(endpoints: s.callEndpoints, token: tok, session: sid)
            check(err == nil, "chamada: ligou \(err ?? "")")
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(250)); if audio > 20000 { break } }
            check(audio > 20000, "chamada: fala logo ao atender (\(audio / 2) amostras)")
            // Espera o cumprimento acabar (sessão ocupada = cumprimento mais longo): senão a fala do teste fica a meio
            // e, ao desligar, o resto ia como prompt para a sessão REAL.
            for _ in 0..<60 { if states.last == "listening" { break }; try await Task.sleep(for: .milliseconds(250)) }
            let a0 = audio
            for c in [silence(0.5), tone(1.0), silence(1.0)] { for i in stride(from: 0, to: c.count, by: 640) { cc.sendMic(Array(c[i..<min(c.count, i + 640)])); try await Task.sleep(for: .milliseconds(20)) } }
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(250)); if audio > a0 + 10000 && states.contains("heard") { break } }
            check(states.contains("heard") && audio > a0 + 10000, "chamada: ouve e responde por voz (\(states.suffix(6).joined(separator: ",")))")
            cc.hangup(); try await Task.sleep(for: .milliseconds(500))
        }
        // 4c. Imagens do Mac no chat: caminho na resposta -> bytes; fora da pasta do utilizador recusado.
        let icon = NSHomeDirectory() + "/Developer/fala/research/fala-icon.png"
        check(Jarvis.mediaPaths("Gerei isto: \(icon). E um vídeo /Users/x/a.mp4") == [icon, "/Users/x/a.mp4"], "media: deteta imagem e vídeo na resposta")
        let fr = await s.jarvis(.init(op: "file", text: icon), timeout: 20)
        check((fr?.file?.count ?? 0) > 1000, "media: imagem do Mac chega ao iPhone (\((fr?.file?.count ?? 0) / 1024) KB)")
        let bad = await s.jarvis(.init(op: "file", text: "/etc/passwd"), timeout: 10)
        let bad2 = await s.jarvis(.init(op: "file", text: NSHomeDirectory() + "/../../etc/x.png"), timeout: 10)
        check(bad?.ok == false && bad2?.ok == false, "media: recusa ficheiros fora da pasta ou que não são imagem/vídeo")
        // 4d. PC Windows com GPU (só se estiver ligado): transcrição e voz fora do MacBook.
        if let tk = UserDefaults(suiteName: "com.fran.fala.mac")?.string(forKey: "fala.token") {
            UserDefaults.standard.set(tk, forKey: "fala.token")
            if await PCNode.isUp() {
                let fr = (0..<Int(16000 * 2.5)).map { Float(sin(Double($0) * 0.05)) * 0.2 }
                let t0 = Date(); let txt = await PCNode.transcribe(fr, prompt: "")
                check(txt != nil, "PC: transcrição na GPU responde (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
                let v = await PCNode.speak("Olá Fran.")
                check((v?.0.count ?? 0) > 10000 && v?.1 == 22050, "PC: voz Piper a 22050 Hz (\((v?.0.count ?? 0) / 2) amostras)")
            } else { print("     PC desligado: testes do PC saltados") }
            UserDefaults.standard.set(tok, forKey: "fala.token") // o Mac falso usa o código de teste (senão "enviar" dá "Código errado")
        }
        // 5. Sessão de teste (só se pedida): enviar prompt e chamada ponta a ponta.
        if args.count >= 2 {
            let sid = args[1]
            let r = await s.jarvis(.init(op: "send", id: sid, text: "Responde só com esta frase, sem ferramentas: O teste do Jarvis correu bem."), timeout: 20)
            check(r?.ok == true, "enviar: prompt entrou no iTerm \(r?.error ?? s.lastError ?? "sem resposta")")
            var got = ""
            for _ in 0..<60 { try await Task.sleep(for: .seconds(1)); if let m = SessionHub.shared.messages(sid, limit: 3).last, m.role == "agent", m.text.contains("Jarvis") { got = m.text; break } }
            check(!got.isEmpty, "enviar: o agente respondeu (\(got.prefix(60)))")
            // Chamada: "fala" 1,2 s de tom; o transcritor falso devolve um prompt; o Jarvis responde por voz.
            // CALL_PROMPT permite testar a sessão ocupada (ex.: pedir um sleep no bash = estado "shell").
            let callPrompt = ProcessInfo.processInfo.environment["CALL_PROMPT"] ?? "Responde só com esta frase, sem ferramentas: A chamada funcionou e a voz está boa."
            mac.transcribe = { _ in callPrompt }
            let cc = CallClient()
            var audio = Data(), rate = 0, states: [String] = [], firstAudio: Date?, spokeAt: Date?, said = ""
            cc.onEvent = { e in states.append(e.state); if e.state == "speaking" { spokeAt = Date(); said = e.text ?? ""; if states.contains("thinking") { audio = Data(); firstAudio = nil } } }
            cc.onAudio = { d, r in if firstAudio == nil { firstAudio = Date() }; audio.append(d); rate = r }
            let err = await cc.connect(endpoints: s.callEndpoints, token: tok, session: sid)
            check(err == nil, "chamada: ligou \(err ?? "")")
            for c in [silence(0.5), tone(1.2), silence(1.0)] { for i in stride(from: 0, to: c.count, by: 640) { cc.sendMic(Array(c[i..<min(c.count, i + 640)])); try await Task.sleep(for: .milliseconds(20)) } }
            // Espera a resposta falada DEPOIS de "thinking" (a saudação também é "speaking").
            for _ in 0..<90 { try await Task.sleep(for: .seconds(1)); if let t = states.lastIndex(of: "thinking"), states[t...].contains("speaking"), states.last == "listening" { break } }
            let ttfa = firstAudio.flatMap { f in spokeAt.map { f.timeIntervalSince($0) } } ?? -1
            check(states.contains("heard") && states.contains("thinking") && states.contains("speaking"), "chamada: ouvir, enviar, pensar, falar (\(states.joined(separator: ",")))")
            check(audio.count > 20000, "chamada: voz recebida \(audio.count / 2) amostras a \(rate) Hz, 1.º áudio \(Int(ttfa * 1000)) ms depois do texto")
            print("     disse: \(said)")
            if !audio.isEmpty { writeWAV(audio, rate: rate, to: "../jarvis/voices/chamada-teste.wav") }
            // Barge-in: falar por cima durante a fala do Jarvis tem de mandar "stop".
            var stopped = false; cc.onStop = { stopped = true }
            mac.transcribe = { _ in "repete" }
            for c in [tone(1.0), silence(1.0)] { for i in stride(from: 0, to: c.count, by: 640) { cc.sendMic(Array(c[i..<min(c.count, i + 640)])); try await Task.sleep(for: .milliseconds(20)) } }
            try await Task.sleep(for: .milliseconds(600))
            for c in [tone(0.8), silence(1.0)] { for i in stride(from: 0, to: c.count, by: 640) { cc.sendMic(Array(c[i..<min(c.count, i + 640)])); try await Task.sleep(for: .milliseconds(20)) } }
            try await Task.sleep(for: .seconds(2))
            check(stopped, "chamada: barge-in pára a voz")
            cc.hangup(); try await Task.sleep(for: .milliseconds(500))
        }
        print(failures == 0 ? "\nTUDO OK" : "\n\(failures) FALHAS")
        exit(failures == 0 ? 0 : 1)
    }
}

func writeWAV(_ pcm: Data, rate: Int, to path: String) {
    var h = Data("RIFF".utf8); func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { h.append(contentsOf: $0) } }
    func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { h.append(contentsOf: $0) } }
    u32(36 + pcm.count); h += Data("WAVEfmt ".utf8); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16); h += Data("data".utf8); u32(pcm.count)
    try? (h + pcm).write(to: URL(fileURLWithPath: path))
}
