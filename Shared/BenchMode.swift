#if DEBUG && canImport(WhisperKit)
import Foundation
import AVFoundation

/// Modo de teste interno (só Debug): lançar com `-falaBench <modelo>` corre o Whisper sobre
/// Documents/bench/*.wav (copiados por devicectl) e escreve Documents/bench/<modelo>.jsonl.
/// Serve para medir latência/precisão no iPhone real sem altifalante->micro.
enum BenchMode {
    static func runIfAsked() {
        let a = ProcessInfo.processInfo.arguments
        #if os(iOS)
        if a.contains("-falaMacTest") { Task { @MainActor in await macTest() }; return }
        #endif
        guard let i = a.firstIndex(of: "-falaBench"), i + 1 < a.count else { return }
        let model = a[i + 1]
        Task.detached(priority: .userInitiated) {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bench")
            let files = ((try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            UserDefaults.standard.set(model, forKey: "fala.whisperModel")
            let eng = WhisperEngine()
            let out = docs.appendingPathComponent("\(model).jsonl")
            var lines: [String] = []
            let t0 = Date()
            _ = await eng.transcribe(load16k(files.first!), waitForModel: true)
            if eng.lastError != nil { _ = await eng.transcribe(load16k(files.first!), waitForModel: true) } // 2.ª tentativa após apagar modelo corrompido
            lines.append("{\"load\": \(Date().timeIntervalSince(t0)), \"err\": \"\(eng.lastError ?? "")\"}")
            for f in files {
                let s = load16k(f); let t = Date()
                let raw = await eng.transcribe(s) ?? ""
                let o: [String: Any] = ["engine": "ios-" + model, "file": f.lastPathComponent, "raw": raw, "clean": TextCleanup.clean(raw), "secs": Date().timeIntervalSince(t), "audio": Double(s.count) / 16000]
                lines.append(String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!)
                try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
            }
            lines.append("{\"done\": true}")
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
    }

    #if os(iOS)
    /// Ponta a ponta sem colunas->micro: envia Documents/bench/*_01.wav e long_joana.wav ao Mac
    /// pelo protocolo de áudio (modo teste, não cola) e escreve Documents/bench/mactest.jsonl.
    @MainActor static func macTest() async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("bench")
        let out = docs.appendingPathComponent("mactest.jsonl")
        let sender = MacSender(); sender.startBrowsing()
        for _ in 0..<40 where !sender.hasMac { try? await Task.sleep(for: .milliseconds(250)) }
        var lines = ["{\"mac\": \"\(sender.macName ?? "nenhum")\", \"paired\": \(sender.paired)}"]
        for name in ["joana_01", "luciana_01", "joananoise_01", "joanaroom_01", "long_joana"] {
            let s = load16k(docs.appendingPathComponent(name + ".wav")); let t = Date()
            let r = await sender.sendAudio(s, enter: false, paste: name == "joana_01", timeout: 120) // a 1.ª cola a sério (histórico + colagem)
            let o: [String: Any] = ["file": name, "text": r ?? "<sem resposta>", "secs": Date().timeIntervalSince(t), "audio": Double(s.count) / 16000]
            lines.append(String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!)
            try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        }
        lines.append("{\"done\": true}")
        try? lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
    }
    #endif

    static func load16k(_ url: URL) -> [Float] {
        guard let f = try? AVAudioFile(forReading: url),
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil, let ch = b.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(b.frameLength))) // ficheiros já em 16 kHz mono
    }
}
#endif
