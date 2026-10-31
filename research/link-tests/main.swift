import VideoToolbox
import CoreMedia
// Testes locais do protocolo iPhone<->Mac (cifra, anti-replay, AAC, retries, fila offline, perda de rede).
// Corre com ./run.sh. Usa o MESMO código da app (Shared/Link.swift, LinkCrypto.swift, AudioCodec.swift, MacSender.swift).
import Foundation
import Network

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ name: String) { print((ok ? "OK   " : "FALHA ") + name); if !ok { failures += 1 } }

/// Mac de teste: mesmo fluxo do MacReceiver.handleV2, com falhas injetáveis.
final class FakeMac: @unchecked Sendable {
    let token: String; let replay = ReplayGuard()
    var listener: NWListener?; var pastes: [String] = []; var history: [String] = []
    var dropNextReply = false; var delay: Double = 0.3
    let q = DispatchQueue(label: "fakemac")
    init(token: String) { self.token = token }
    func start(port: UInt16) {
        let l = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        l.newConnectionHandler = { [self] c in
            c.start(queue: q); var buf = Data()
            func read() { c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, err in
                if let d { buf.append(d) }
                let full = LinkCrypto.frameLength(buf).map { buf.count >= $0 } ?? false
                if full || done || err != nil { self.handle(buf, c) } else { read() } } }
            read()
        }
        l.start(queue: q); listener = l
    }
    func stop() { listener?.cancel(); listener = nil }
    func handle(_ raw: Data, _ c: NWConnection) {
        guard let req = LinkCrypto.open(raw, token: token) else { c.send(content: Data("N".utf8), isComplete: true, completion: .contentProcessed { _ in c.cancel() }); return }
        let send: (Data) -> Void = { b in c.send(content: LinkCrypto.sealReply(b, id: req.id, token: self.token), isComplete: true, completion: .contentProcessed { _ in c.cancel() }) }
        switch replay.check(req) {
        case .stale: send(Data("E".utf8)); return
        case .duplicate(let r): send(r ?? Data("B".utf8)); return
        case .fresh: break
        }
        let m = req.body.first!
        if m == 0x50 { let o = Data("PFakeMac".utf8); replay.store(req.id, reply: o); send(o); return }
        q.asyncAfter(deadline: .now() + delay) { [self] in
            let pcm = Link.decodeAudioV2(req.body)
            let text = "audio \(pcm.count / 1600) ds"
            if m == 0x41 { pastes.append(text) } else if m == 0x48 { history.append(text) }
            let o = Data(("T" + text).utf8); replay.store(req.id, reply: o)
            if dropNextReply { dropNextReply = false; c.cancel() } else { send(o) }
        }
    }
}

func tone(_ secs: Double) -> [Float] { (0..<Int(secs * 16000)).map { Float(sin(Double($0) * 0.07)) * 0.3 } }

@main struct LinkTests {
    @MainActor static func main() async throws {
        // Modo e2e: `linktests e2e <porta> <wav>` fala com a app do Mac a sério (modo teste, não cola).
        let a = CommandLine.arguments
        if a.count == 4, a[1] == "e2e" {
            UserDefaults.standard.set(ProcessInfo.processInfo.environment["FALA_TOKEN"] ?? "", forKey: "fala.token")
            let s = MacSender(outboxDir: FileManager.default.temporaryDirectory.appendingPathComponent("fala-e2e"))
            s.fixedEndpoints = [.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(a[2])!)!)]
            print("ping:", await s.ping() ?? "nil", s.latencyMs ?? -1, "ms", s.lastError ?? "")
            let t = Date()
            let r = await s.sendAudio(BenchLoad.load16k(URL(fileURLWithPath: a[3])), enter: false, paste: false, timeout: 120)
            print("texto:", r ?? "nil", String(format: "(%.2f s)", Date().timeIntervalSince(t)), s.lastError ?? "")
            exit(r == nil ? 1 : 0)
        }
        // Ecrã ao vivo: `linktests live <porta> [segundos]` liga ao ScreenStream da app do Mac e mede o vídeo.
        if a.count >= 3, a[1] == "live" {
            let tk = ProcessInfo.processInfo.environment["FALA_TOKEN"] ?? ""
            let c = LiveScreenClient()
            var frames = 0, bytes = 0, size = CGSize.zero, decodable = 0, dec: VTDecompressionSession?, lastErr: OSStatus = 0
            c.onSample = { sb, sz in
                frames += 1; size = sz; bytes += CMSampleBufferGetTotalSampleSize(sb)
                // Descodifica a sério (como o iPhone): só conta se o VideoToolbox der uma imagem.
                if let f = sb.formatDescription {
                    if dec == nil { VTDecompressionSessionCreate(allocator: nil, formatDescription: f, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &dec) }
                    if let dec { VTDecompressionSessionDecodeFrame(dec, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { st, _, img, _, _ in if st == noErr, img != nil { decodable += 1 } else { lastErr = st } } }
                }
            }
            let ok = await c.connect(endpoints: [.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(a[2])!)!)], token: tk, width: 1600, monitor: nil)
            guard ok else { print("live: não ligou"); exit(1) }
            let secs = a.count > 3 ? Double(a[3])! : 3
            c.send(["kf": 1])
            try await Task.sleep(for: .seconds(secs))
            c.close()
            print(String(format: "live: %d frames em %.0f s (%.1f img/s), %d KB/frame, %dx%d, descodificados %d (erro %d)", frames, secs, Double(frames) / secs, frames > 0 ? bytes / frames / 1024 : 0, Int(size.width), Int(size.height), decodable, Int(lastErr)))
            exit(frames > 0 ? 0 : 1)
        }
        // Medição do ecrã remoto: `linktests screen <porta> [n]` (pede n imagens seguidas à app do Mac).
        if a.count >= 3, a[1] == "screen" {
            UserDefaults.standard.set(ProcessInfo.processInfo.environment["FALA_TOKEN"] ?? "", forKey: "fala.token")
            let s = MacSender(outboxDir: FileManager.default.temporaryDirectory.appendingPathComponent("fala-e2e"))
            s.fixedEndpoints = [.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(a[2])!)!)]
            let n = a.count > 3 ? Int(a[3])! : 30
            var bytes = 0, same = 0, fails = 0, have: String?; let t = Date()
            for _ in 0..<n {
                guard let d = await s.screen(width: 1600, have: have, monitor: ProcessInfo.processInfo.environment["MON"].flatMap { UInt32($0) }) else { fails += 1; continue }
                if d.isEmpty { same += 1 } else { bytes += d.count; have = Link.digest(d); try? d.write(to: URL(fileURLWithPath: "/tmp/fala-screen.img")) }
            }
            let dt = Date().timeIntervalSince(t), got = n - fails - same
            print(String(format: "ecrã: %.1f img/s, %.0f ms/img, %d KB/img, %d iguais, %d falhas", Double(n - fails) / dt, dt * 1000 / Double(n), got > 0 ? bytes / got / 1024 : 0, same, fails), s.lastError ?? "")
            exit(fails > 0 ? 1 : 0)
        }
        // 1. Cifra
        let tok = "K7QX2M9PAB", id = LinkCrypto.newID()
        let sealed = LinkCrypto.seal(Data("olá".utf8), id: id, token: tok)
        check(LinkCrypto.open(sealed, token: tok)?.body == Data("olá".utf8), "cifra: ida e volta")
        check(LinkCrypto.open(sealed, token: "OUTROCODIG") == nil, "cifra: código errado não abre")
        var bad = sealed; bad[bad.count - 20] ^= 1
        check(LinkCrypto.open(bad, token: tok) == nil, "cifra: mensagem adulterada recusada")
        check(!sealed.contains(Data("olá".utf8)), "cifra: nada em claro no fio")
        // 2. Anti-replay
        let g = ReplayGuard(), r = LinkCrypto.open(sealed, token: tok)!
        if case .fresh = g.check(r) { check(true, "replay: 1.ª vez aceite") } else { check(false, "replay: 1.ª vez aceite") }
        g.store(r.id, reply: Data("T1".utf8))
        if case .duplicate(let c) = g.check(r) { check(c == Data("T1".utf8), "replay: repetido devolve a resposta guardada") } else { check(false, "replay: repetido") }
        let old = LinkCrypto.open(LinkCrypto.seal(Data("x".utf8), id: LinkCrypto.newID(), token: tok, now: Date().addingTimeInterval(-3600)), token: tok)!
        if case .stale = g.check(old) { check(true, "replay: mensagem com 1 h recusada") } else { check(false, "replay: velha") }
        // 3. AAC
        let wav = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
        let pcm = BenchLoad.load16k(URL(fileURLWithPath: wav))
        let aac = AudioCodec.encodeAAC(pcm)!
        let back = AudioCodec.decode(aac)!
        print(String(format: "     AAC: %.1f s de áudio, PCM %d KB -> AAC %d KB (%.0fx)", Double(pcm.count) / 16000, pcm.count * 2 / 1024, aac.count / 1024, Double(pcm.count * 2) / Double(aac.count)))
        check(aac.count * 6 < pcm.count * 2 && abs(back.count - pcm.count) < 4000, "AAC: 6x+ mais pequeno e mesma duração")

        // 4-7. Rede
        UserDefaults.standard.set(tok, forKey: "fala.token")
        let port: UInt16 = 47911
        let mac = FakeMac(token: tok)
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("fala-outbox-\(UUID().uuidString)")
        let sender = MacSender(outboxDir: outbox)
        sender.fixedEndpoints = [.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)]; sender.legacyFallback = false

        // Mac desligado: falha rápido, vai para a fila.
        var t = Date()
        let r1 = await sender.sendAudio(tone(2), enter: false, timeout: 3, queueOnFail: true)
        check(r1 == nil && Date().timeIntervalSince(t) < 4.5, "Mac fora: desiste no prazo")
        check(sender.pending == 1, "Mac fora: áudio guardado na fila")
        // Mac volta: a fila sai sozinha e cola (recente).
        mac.start(port: port); try await Task.sleep(for: .milliseconds(300))
        await sender.flush()
        check(sender.pending == 0 && mac.pastes.count == 1, "Mac volta: fila entregue e colada 1 vez")
        // Ping + latência.
        let name = await sender.ping()
        check(name == "FakeMac" && (sender.latencyMs ?? 9999) < 500, "ping: nome e latência (\(sender.latencyMs ?? -1) ms)")
        // Resposta perdida a meio: retry com o mesmo id não cola 2x.
        mac.dropNextReply = true
        t = Date()
        let r2 = await sender.sendAudio(tone(1.5), enter: false, timeout: 8)
        check(r2 != nil && mac.pastes.count == 2, "resposta perdida: retry recupera o texto sem colar 2x (\(String(format: "%.1f", Date().timeIntervalSince(t))) s)")
        // Rede cai e volta durante o envio (Mac reinicia 1 s depois).
        mac.stop(); try await Task.sleep(for: .milliseconds(200))
        Task { try await Task.sleep(for: .seconds(1)); mac.start(port: port) }
        let r3 = await sender.sendAudio(tone(1), enter: false, timeout: 8)
        check(r3 != nil && mac.pastes.count == 3, "rede cai 1 s: backoff volta a ligar e entrega")
        // Código errado.
        UserDefaults.standard.set("ERRADOERRA", forKey: "fala.token")
        let r4 = await sender.ping(timeout: 3)
        check(r4 == nil && (sender.lastError ?? "").contains("Código"), "código errado: recusado com mensagem clara")
        UserDefaults.standard.set(tok, forKey: "fala.token")
        // Item antigo na fila: só histórico.
        mac.stop(); try await Task.sleep(for: .milliseconds(200))
        _ = await sender.sendAudio(tone(1), enter: false, timeout: 1.5, queueOnFail: true)
        for f in try FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil) where f.pathExtension == "json" {
            var j = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
            j["created"] = (j["created"] as! Double) - 600; try JSONSerialization.data(withJSONObject: j).write(to: f)
        }
        mac.start(port: port); try await Task.sleep(for: .milliseconds(300))
        await sender.flush()
        check(mac.history.count == 1 && mac.pastes.count == 3, "fila com 10 min: vai só para o histórico, não cola")
        UserDefaults.standard.removeObject(forKey: "fala.token")
        print(failures == 0 ? "\nTudo OK" : "\n\(failures) falha(s)")
        exit(failures == 0 ? 0 : 1)
    }
}
