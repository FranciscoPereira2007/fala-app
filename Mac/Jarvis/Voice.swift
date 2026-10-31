import Foundation

/// Voz do Jarvis. Motor: Piper pt_PT (local, grátis), processo sempre aberto com o modelo em memória:
/// cada frase sai assim que fica pronta (1.º áudio ~0,1 a 0,3 s). O motor maior (Qwen3-TTS / Chatterbox)
/// entra aqui quando houver disco; a interface fica igual.
final class JarvisVoice: @unchecked Sendable {
    static let shared = JarvisVoice()
    private let q = DispatchQueue(label: "fala.tts")
    private var proc: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private(set) var sampleRate = 22050
    private var generation = 0

    static let python = NSHomeDirectory() + "/dictate/piper-venv/bin/python3"
    static let model = NSHomeDirectory() + "/dictate/piper-voices/pt_PT-tugão-medium.onnx"
    var available: Bool { FileManager.default.isExecutableFile(atPath: Self.python) && FileManager.default.fileExists(atPath: Self.model) }

    /// Servidor: lê uma frase por linha, devolve blocos [UInt32 BE tamanho][PCM Int16] e 0 no fim da frase.
    static let server = """
    import sys, struct
    from piper import PiperVoice
    v = PiperVoice.load(sys.argv[1])
    out = sys.stdout.buffer
    out.write(struct.pack('>I', v.config.sample_rate)); out.flush()
    for line in sys.stdin:
        t = line.strip()
        if t:
            for ch in v.synthesize(t):
                b = ch.audio_int16_bytes
                out.write(struct.pack('>I', len(b))); out.write(b); out.flush()
        out.write(struct.pack('>I', 0)); out.flush()
    """

    /// Ao abrir a chamada: escolhe já a voz (o "say -v ?" demora ~1,6 s) e só arranca a Piper se for a voz escolhida.
    func warmUp() {
        kokoro.warmUp()
        DispatchQueue.global(qos: .userInitiated).async { _ = Self.bestVoice }
        if UserDefaults.standard.string(forKey: "fala.voice") == "piper" { q.async { _ = self.ensure() } }
    }

    private func ensure() -> Bool {
        if let p = proc, p.isRunning { return true }
        guard available else { return false }
        let s = ITerm.support.appendingPathComponent("piper_server.py")
        try? FileManager.default.createDirectory(at: ITerm.support, withIntermediateDirectories: true)
        try? Self.server.write(to: s, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: Self.python); p.arguments = [s.path, Self.model]
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        proc = p; input = i.fileHandleForWriting; output = o.fileHandleForReading
        guard let r = readU32() else { proc = nil; return false }
        sampleRate = Int(r)
        return true
    }

    private func readU32() -> UInt32? {
        guard let d = readExactly(4) else { return nil }
        return d.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Sem som nas chamadas era isto: num pipe, read(upToCount:) devolve no máx. ~64 KB; um bloco de voz tem
    /// ~150 KB, o resto ficava no pipe e era lido como "tamanho" do bloco seguinte (fluxo trocado, voz muda).
    private func readExactly(_ n: Int) -> Data? {
        var d = Data(capacity: n)
        while d.count < n {
            guard let part = try? output?.read(upToCount: n - d.count), !part.isEmpty else { return nil }
            d.append(part)
        }
        return d
    }

    /// Joana (say do macOS) a 22050 Hz Int16, frase a frase; pára no barge-in.
    /// Melhor voz pt-PT instalada: Premium > Melhorada/Enhanced > Joana básica (descarregar em Definições > Acessibilidade > Conteúdo falado).
    /// Volta a procurar de minuto a minuto: uma voz descarregada a meio entra sem reiniciar a Fala.
    private static var voiceCache: (name: String, at: Date)?
    static var bestVoice: String {
        if let c = voiceCache {
            if Date().timeIntervalSince(c.at) > 60 { voiceCache = (c.name, Date()); DispatchQueue.global().async { voiceCache = (findBestVoice(), Date()) } } // refresca sem atrasar a frase
            return c.name
        }
        let v = findBestVoice(); voiceCache = (v, Date()); return v
    }
    private static func findBestVoice() -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = ["-v", "?"]
        let out = Pipe(); p.standardOutput = out
        guard (try? p.run()) != nil else { return "Joana" }
        p.waitUntilExit()
        let names = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n")
            .filter { $0.contains("pt_PT") }
            .map { String($0.split(separator: "pt_PT")[0]).trimmingCharacters(in: .whitespaces) }
        return names.first { $0.contains("Premium") } ?? names.first { $0.contains("Melhorada") || $0.contains("Enhanced") } ?? "Joana"
    }

    private func speakJoana(_ text: String, chunk: @escaping (Data) -> Void) -> Bool {
        cancelled = false
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fala-joana.wav")
        for sentence in SpokenSummary.splitSentences(text.replacingOccurrences(of: "\n", with: " ")) where !sentence.isEmpty {
            if cancelled { break }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = ["-v", Self.bestVoice, "-r", "195", "-o", tmp.path, "--file-format=WAVE", "--data-format=LEI16@22050", sentence]
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            guard p.terminationStatus == 0, let wav = try? Data(contentsOf: tmp), let r = wav.range(of: Data("data".utf8)) else { return false }
            if cancelled { break }
            chunk(Data(wav[(r.upperBound + 4)...]))
        }
        cancelled = false
        return true
    }

    /// Voz no PC (mesma voz Piper, a 22050 Hz): frase a frase, pára no barge-in. false = PC fora, usa o Mac.
    private func speakOnPC(_ text: String, voice: String = "", chunk: @escaping (Data) -> Void) -> Bool {
        let sem = DispatchSemaphore(value: 0); var up = false
        Task { up = await PCNode.isUp(); sem.signal() }; sem.wait()
        guard up else { return false }
        cancelled = false
        for sentence in SpokenSummary.splitSentences(text.replacingOccurrences(of: "\n", with: " ")) {
            var out: (Data, Int)?
            Task { out = await PCNode.speak(sentence, voice: voice); sem.signal() }; sem.wait()
            guard let (pcm, rate) = out, rate == sampleRate else { return false }
            if cancelled { break }
            chunk(pcm)
        }
        cancelled = false
        return true
    }

    /// Sintetiza frase a frase e entrega cada bloco PCM Int16 assim que sai. `cancel()` pára entre blocos.
    /// Devolve false se o motor não arrancou.
    func speak(_ text: String, chunk: @escaping (Data) -> Void) -> Bool {
        // Voz feminina pt-PT (Joana do macOS) por defeito: leve e sem modelo. "fala.voice" = "piper" volta à voz antiga.
        // Voz: Chatterbox feminina no PC (natural) -> Joana do macOS (leve) -> Piper (PC/Mac).
        let v = UserDefaults.standard.string(forKey: "fala.voice") ?? "chatterbox"
        if v == "chatterbox", speakOnPC(text, voice: "chatterbox", chunk: chunk) { return true }
        if v != "joana", kokoro.speak(text, chunk: chunk) { CallLog.w("voz: kokoro"); return true } // a mais natural: ganha à Piper e à Joana
        CallLog.w("voz: kokoro indisponível (instalado=\(kokoro.installed) pronto=\(kokoro.ready))")
        if v != "piper", speakJoana(text, chunk: chunk) { return true }
        if speakOnPC(text, chunk: chunk) { return true }
        var ok = false
        q.sync {
            guard ensure(), let input else { return }
            generation += 1; let gen = generation
            ok = true; cancelled = false
            for sentence in SpokenSummary.splitSentences(text.replacingOccurrences(of: "\n", with: " ")) {
                input.write(Data((sentence + "\n").utf8))
                while let n = readU32(), n > 0 {
                    guard let d = readExactly(Int(n)) else { break }
                    if gen == generation, !cancelled { chunk(d) }
                }
                if cancelled { break }
            }
            cancelled = false
        }
        return ok
    }

    private var cancelledFlag = false
    private let flagLock = NSLock()
    private var cancelled: Bool {
        get { flagLock.lock(); defer { flagLock.unlock() }; return cancelledFlag }
        set { flagLock.lock(); cancelledFlag = newValue; flagLock.unlock() }
    }
    /// Barge-in: pára a fala em curso (a frase que já está a sair é descartada).
    func cancel() { cancelled = true; kokoro.cancel() }

    /// Kokoro pt-PT (logus2k/kokoro_tts_eu_pt, local e grátis): muito mais natural e percetível que a Piper.
    /// Arranca com a app (demora 11 a 25 s a carregar); até estar pronto, fala a Joana.
    let kokoro = StreamTTS(python: NSHomeDirectory() + "/dictate/kokoro-venv/bin/python", script: "kokoro_server.py", source: kokoroServer,
                           args: [NSHomeDirectory() + "/dictate/kokoro-models"], needs: NSHomeDirectory() + "/dictate/kokoro-models/tuga_kokoro.pth")

    static let kokoroServer = """
# Servidor Kokoro pt-PT (logus2k/kokoro_tts_eu_pt), mesmo protocolo do piper_server da Fala:
# stdin: uma frase por linha. stdout: [UInt32 BE sample_rate] uma vez; por bloco [UInt32 BE len][PCM int16 mono]; 0 no fim da frase.
# Uso: kokoro-venv/bin/python kokoro_server.py [pasta_modelos]
import sys, os, struct, re
import numpy as np
d = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/dictate/kokoro-models")
import torch
torch.set_num_threads(max(1, (os.cpu_count() or 4)))
from tts_eu_pt import TTS, SAMPLE_RATE, g2p
tts = TTS(device="cpu", model_path=os.path.join(d, "tuga_kokoro.pth"), voicepack_path=os.path.join(d, "tuga_voicepack.pt"))
out = sys.stdout.buffer

def synth(t):
    ps = g2p.phonemize(t)[:510]
    if not ps.strip():
        return None
    with torch.no_grad():
        a = tts.km(ps, tts.pack[len(ps) - 1], 1.0, return_output=True).audio
    a = a.cpu().numpy()
    # 24 kHz -> 22050 Hz: a chamada anuncia uma só taxa (a mesma da Joana e da Piper).
    a = np.interp(np.arange(0, len(a), SAMPLE_RATE / 22050.0), np.arange(len(a)), a)
    return (np.clip(a, -1, 1) * 32767).astype("<i2").tobytes()

synth("Olá.")  # aquece o modelo antes de anunciar o sample rate
out.write(struct.pack('>I', 22050)); out.flush()
for line in sys.stdin:
    t = line.strip()
    if t:
        # blocos por oração (vírgulas) para o 1.º áudio sair mais cedo em frases longas
        parts = [p.strip() for p in re.split(r'(?<=[,;:])\\s+', t) if p.strip()]
        for p in parts:
            try:
                b = synth(p)
            except Exception:
                b = None
            if b:
                out.write(struct.pack('>I', len(b))); out.write(b); out.flush()
    out.write(struct.pack('>I', 0)); out.flush()
"""
}

/// Motor de voz num processo sempre aberto (protocolo da Piper): uma frase por linha, PCM Int16 por blocos, 0 no fim.
final class StreamTTS: @unchecked Sendable {
    private let python: String, script: String, source: String, args: [String], needs: String
    private let q = DispatchQueue(label: "fala.tts.stream")
    private var proc: Process?, input: FileHandle?, output: FileHandle?
    private(set) var ready = false
    private var starting = false
    private let lock = NSLock()
    private var cancelledFlag = false
    private var cancelled: Bool { get { lock.withLock { cancelledFlag } } set { lock.withLock { cancelledFlag = newValue } } }

    init(python: String, script: String, source: String, args: [String], needs: String) {
        self.python = python; self.script = script; self.source = source; self.args = args; self.needs = needs
    }
    var installed: Bool { FileManager.default.isExecutableFile(atPath: python) && FileManager.default.fileExists(atPath: needs) }

    /// Arranca em fundo (sem bloquear quem chama).
    func warmUp() {
        lock.lock(); let go = !starting && !ready && installed; if go { starting = true }; lock.unlock()
        guard go else { return }
        q.async { [self] in _ = start(); lock.withLock { starting = false } }
    }

    private func start() -> Bool {
        if let p = proc, p.isRunning, ready { return true }
        let s = ITerm.support.appendingPathComponent(script)
        try? FileManager.default.createDirectory(at: ITerm.support, withIntermediateDirectories: true)
        try? source.write(to: s, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: python); p.arguments = [s.path] + args
        let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in self?.ready = false }
        guard (try? p.run()) != nil else { return false }
        proc = p; input = i.fileHandleForWriting; output = o.fileHandleForReading
        guard let r = readU32() else { CallLog.w("kokoro: não arrancou"); proc = nil; return false }
        CallLog.w("kokoro: pronto (\(r) Hz)")
        ready = true
        return true
    }

    private func readU32() -> UInt32? {
        guard let d = readExactly(4) else { return nil }
        return d.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Sem som nas chamadas era isto: num pipe, read(upToCount:) devolve no máx. ~64 KB; um bloco de voz tem
    /// ~150 KB, o resto ficava no pipe e era lido como "tamanho" do bloco seguinte (fluxo trocado, voz muda).
    private func readExactly(_ n: Int) -> Data? {
        var d = Data(capacity: n)
        while d.count < n {
            guard let part = try? output?.read(upToCount: n - d.count), !part.isEmpty else { return nil }
            d.append(part)
        }
        return d
    }

    /// false = ainda não está pronto (quem chama usa outra voz).
    func speak(_ text: String, chunk: @escaping (Data) -> Void) -> Bool {
        guard ready else { warmUp(); return false }
        var ok = false
        q.sync {
            guard ready, let input else { return }
            ok = true; cancelled = false
            for sentence in SpokenSummary.splitSentences(text.replacingOccurrences(of: "\n", with: " ")) where !sentence.isEmpty {
                input.write(Data((sentence + "\n").utf8))
                while let n = readU32(), n > 0 {
                    guard let d = readExactly(Int(n)) else { break }
                    if !cancelled { chunk(d) }
                }
                if cancelled { break }
            }
            cancelled = false
        }
        return ok
    }
    func cancel() { cancelled = true }
}
