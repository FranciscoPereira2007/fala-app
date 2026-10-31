import Foundation
import Speech
import AVFoundation

/// STT grátis e local. Por defeito: SpeechAnalyzer/SpeechTranscriber (iOS/macOS 26, on-device,
/// pt-PT). Sem ele: SFSpeechRecognizer on-device. Opcional no Mac: Whisper (WhisperKit) no fim.
@MainActor final class Transcriber: ObservableObject {
    @Published var text = ""
    @Published var level: Float = 0
    @Published var isRecording = false
    @Published var error: String?
    private(set) var seconds: Double = 0
    private var startedAt = Date()

    /// Motor escolhido nas definições ("fala.engine"): auto | apple | legacy | whisper.
    enum Engine: String, CaseIterable { case auto, apple, legacy, whisper }
    static var engineSetting: Engine {
        get { Engine(rawValue: UserDefaults.standard.string(forKey: "fala.engine") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "fala.engine") }
    }
    /// Motor que está mesmo a correr (para a UI/diagnóstico).
    @Published private(set) var activeEngine = ""

    private let engine = AVAudioEngine()
    private let sink = AudioSink()
    private var generation = 0
    private var starting: Task<Void, Never>?
    private var modern: AnyObject?          // AnalyzerSession (iOS/macOS 26)
    private var modernReady: Bool?
    private var whisperFinal = false
    /// Guardar o áudio (16 kHz mono) para o enviar ao Mac no fim (aba Mac do iPhone).
    var keepAudio = false
    /// Áudio gravado no último ditado (só com keepAudio ou Whisper local).
    private(set) var lastAudio: [Float] = []

    init() {
        if #available(iOS 26.0, macOS 26.0, *) {
            Task { [weak self] in let ok = await AnalyzerSession.prepare(); self?.modernReady = ok; falaLog("SpeechAnalyzer pronto: \(ok)") }
        } else { modernReady = false }
        #if canImport(WhisperKit)
        if Self.usesWhisper { WhisperEngine.shared.warmUp() }
        #if DEBUG
        BenchMode.runIfAsked()
        #endif
        #endif
    }

    func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        #if os(iOS)
        let mic = await AVAudioApplication.requestRecordPermission()
        #else
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        if #available(iOS 26.0, macOS 26.0, *), modernReady != true { modernReady = await AnalyzerSession.prepare() }
        // O SpeechAnalyzer não precisa da autorização do reconhecimento de fala, só do micro.
        return (speech || modernReady == true) && mic
    }

    /// Whisper no fim (áudio completo) por cima da pré-visualização ao vivo da Apple.
    static var usesWhisper: Bool {
        switch engineSetting {
        case .whisper: return true
        case .auto: return whisperByDefault
        default: return false
        }
    }
    /// Escolha do benchmark (research/stt-benchmark/RESULTS.md).
    /// Mac: Whisper turbo (WER 8%). iPhone (A13): SpeechAnalyzer da Apple (WER 11%, 0,07 s);
    /// o Whisper base no iPhone 11 devolveu vazio e demora ~3 s por frase.
    #if os(macOS)
    static let whisperByDefault = true
    #else
    static let whisperByDefault = false
    #endif

    private var wantsModern: Bool {
        switch Self.engineSetting {
        case .legacy: return false
        default: return modernReady != false
        }
    }

    /// Pausar/Continuar (botões da Live Activity e da aba Ditar): o motor fica a correr, o áudio não entra.
    @Published private(set) var paused = false
    func setPaused(_ on: Bool) { paused = on; sink.paused = on; if on { level = 0 } }

    /// "Novo": devolve o áudio até aqui e continua a gravar o seguinte sem parar o micro.
    /// A pré-visualização passa a mostrar só o que vem depois do corte (`fresh`).
    func cut() -> [Float] {
        cutPrefix = text
        return sink.takeRecording()
    }
    @Published private(set) var cutPrefix = ""
    /// O que veio depois do último "Novo". O reconhecedor pode rever pontuação do que já disseste ("Bom dia hoje" ->
    /// "Bom dia, hoje"): sem o prefixo exato, corta pelo número de palavras, que não muda com a pontuação.
    var fresh: String {
        if cutPrefix.isEmpty { return text }
        if text.hasPrefix(cutPrefix) { return String(text.dropFirst(cutPrefix.count)).trimmingCharacters(in: .whitespaces) }
        let n = cutPrefix.split(whereSeparator: \.isWhitespace).count
        return text.split(whereSeparator: \.isWhitespace).dropFirst(n).joined(separator: " ")
    }

    /// Chamada de voz (ver DotCallView): gravar sem calar o que está a tocar.
    var callMode = false

    func start() {
        guard !isRecording else { return }
        text = ""; cutPrefix = ""; error = nil; resetLegacy(); setPaused(false)
        #if os(iOS)
        // Numa chamada (Jarvis) o áudio tem de tocar e gravar ao mesmo tempo: .record calava a voz dele.
        // Chamada: a sessão já foi configurada pela voz (DotVoice.route); mexer-lhe outra vez fazia um estalo a cada turno.
        if callMode { if AVAudioSession.sharedInstance().category != .playAndRecord { try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP]) } }
        else { try? AVAudioSession.sharedInstance().setCategory(.record, mode: .default, options: .duckOthers) }
        try? AVAudioSession.sharedInstance().setActive(true)
        // Sempre o microfone do iPhone (no carro/CarPlay e com auriculares o do aparelho ouve pior).
        let s = AVAudioSession.sharedInstance()
        if let builtIn = s.availableInputs?.first(where: { $0.portType == .builtInMic }) { try? s.setPreferredInput(builtIn) }
        #endif
        generation += 1
        let gen = generation, sink = self.sink
        whisperFinal = false
        #if canImport(WhisperKit)
        whisperFinal = Self.usesWhisper && WhisperEngine.shared.isReady
        if Self.usesWhisper, !whisperFinal { WhisperEngine.shared.warmUp() } // 1.ª vez: descarrega, usa Apple entretanto
        #endif
        sink.reset(record: whisperFinal || keepAudio); lastAudio = []
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
            sink.push(buf)
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength); var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = min(1, sqrt(sum / Float(max(n, 1))) * 20)
            Task { @MainActor in if self?.paused != true { self?.level = rms } }
        }
        do { try engine.start(); isRecording = true; startedAt = Date() } catch { self.error = error.localizedDescription; return }

        if #available(iOS 26.0, macOS 26.0, *), wantsModern {
            starting = Task { [weak self] in
                do {
                    let s = try await AnalyzerSession.start { fi, vo in
                        Task { @MainActor in
                            guard let self, self.generation == gen else { return }
                            self.text = joinText(fi, vo)
                        }
                    }
                    guard let self, self.generation == gen else { s.cancel(); return }
                    self.modern = s; self.activeEngine = self.whisperFinal ? "whisper" : "speechAnalyzer"
                    falaLog("motor: \(self.activeEngine)")
                    sink.attach { s.append($0) }
                } catch {
                    falaLog("SpeechAnalyzer falhou: \(error)")
                    guard let self, self.generation == gen else { return }
                    self.modernReady = false
                    self.startLegacyEngine()
                }
            }
        } else {
            startLegacyEngine()
        }
    }

    /// Para e devolve o texto final.
    func stop() async -> String {
        guard isRecording else { return text }
        let heard = text
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        isRecording = false; level = 0; seconds = Date().timeIntervalSince(startedAt); setPaused(false)
        await starting?.value; starting = nil
        var out: String
        if #available(iOS 26.0, macOS 26.0, *), let s = modern as? AnalyzerSession {
            modern = nil
            out = await s.finish()
            sink.attach(nil)
        } else {
            out = await stopLegacy()
        }
        if out.count < heard.count { out = heard }
        let pcm = (whisperFinal || keepAudio) ? sink.takeRecording() : []
        if keepAudio { lastAudio = pcm }
        #if canImport(WhisperKit)
        if whisperFinal {
            // Se o Whisper devolver muito menos do que se ouviu ao vivo, desconfia e fica com o ao vivo.
            if let w = await WhisperEngine.shared.transcribe(pcm), !w.isEmpty,
               w.split(separator: " ").count * 2 >= out.split(separator: " ").count { out = w; activeEngine = "whisper" }
        }
        #endif
        text = out
        return out
    }

    // MARK: - SFSpeechRecognizer (iOS/macOS < 26 ou sem o modelo novo)

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-PT"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    // Segmentos já fechados: o reconhecedor recomeça o bestTranscription depois de uma pausa.
    private var committed = ""
    private var partial = ""
    private var gotFinal = false
    private var stopping = false
    private var restarts = 0
    private let box = RequestBox()

    private func resetLegacy() { committed = ""; partial = ""; gotFinal = false; stopping = false; restarts = 0 }

    private func startLegacyEngine() {
        guard let recognizer, recognizer.isAvailable else { error = "Reconhecimento indisponível"; return }
        activeEngine = "sfspeech"; falaLog("motor: sfspeech")
        startTask()
        let box = self.box
        sink.attach { box.append($0) }
    }

    /// Uma tarefa de reconhecimento. Se o reconhecedor fechar a meio (pausa longa, fim de
    /// segmento, "no speech"), abre outra e continua a acumular.
    private func startTask() {
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req; box.set(req)
        task = recognizer.recognitionTask(with: req) { [weak self] res, err in
            let t = res?.bestTranscription.formattedString ?? ""
            let final = res?.isFinal ?? false
            let closed = final || res?.speechRecognitionMetadata != nil
            let ended = final || (err != nil && res == nil)
            Task { @MainActor in
                guard let self, self.request === req else { return }
                if res != nil { self.ingest(t, closed: closed) }
                if ended {
                    // Fecha o segmento desta tarefa antes de abrir a seguinte (sem isto repetia/perdia).
                    if !self.partial.isEmpty { self.committed = joinText(self.committed, self.partial); self.partial = "" }
                    if self.isRecording && !self.stopping && self.restarts < 200 { self.restarts += 1; self.startTask() }
                    else {
                        self.gotFinal = true
                        if let err, self.isRecording, !self.stopping { self.error = err.localizedDescription }
                    }
                }
            }
        }
    }

    /// Junta resultados parciais sem perder o que já foi dito antes de uma pausa.
    private func ingest(_ t: String, closed: Bool) {
        let join = joinText
        if t.isEmpty {
            if closed, !partial.isEmpty { committed = join(committed, partial); partial = "" }
            text = join(committed, partial); return
        }
        // Reinício silencioso dentro da tarefa: o novo parcial já não começa como o anterior.
        if !partial.isEmpty, t.count < partial.count / 2,
           !partial.lowercased().hasPrefix(String(t.lowercased().prefix(max(1, min(t.count, 6))))) {
            committed = join(committed, partial)
        }
        if closed { if !(partial.isEmpty && committed.hasSuffix(t)) { committed = join(committed, t) }; partial = "" } else { partial = t }
        text = join(committed, partial)
    }

    private func stopLegacy() async -> String {
        stopping = true
        request?.endAudio()
        for _ in 0..<30 where !gotFinal { try? await Task.sleep(for: .milliseconds(50)) }
        task?.cancel(); task = nil; request = nil; box.set(nil)
        if !partial.isEmpty { committed = joinText(committed, partial); partial = "" }
        return committed
    }
}

/// Pedido atual do SFSpeech, partilhado com a thread de áudio.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var req: SFSpeechAudioBufferRecognitionRequest?
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); req = r; lock.unlock() }
    func append(_ b: AVAudioPCMBuffer) { lock.lock(); req?.append(b); lock.unlock() }
}

/// Recebe o áudio do micro na thread de áudio. Guarda o que chega antes de o motor estar
/// pronto (nada se perde no arranque) e, se pedido, grava 16 kHz mono para o Whisper.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var consumer: ((AVAudioPCMBuffer) -> Void)?
    private var pending: [AVAudioPCMBuffer] = []
    private var record = false
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private let rec16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    func reset(record: Bool) {
        lock.lock(); consumer = nil; pending = []; samples = []; self.record = record; converter = nil; lock.unlock()
    }

    func attach(_ c: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock(); consumer = c
        let p = pending; pending = []
        if let c { p.forEach(c) }
        lock.unlock()
    }

    /// Pausa sem desligar o micro (o iOS não deixa voltar a abri-lo em segundo plano): os buffers são ignorados.
    var paused = false

    func push(_ b: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if paused { return }
        if record { appendRecording(b) }
        if let consumer { consumer(b) } else if pending.count < 3000, let copy = b.copy() as? AVAudioPCMBuffer { pending.append(copy) }
    }

    func takeRecording() -> [Float] { lock.lock(); defer { lock.unlock() }; let s = samples; samples = []; return s }

    private func appendRecording(_ b: AVAudioPCMBuffer) {
        if converter == nil || converter?.inputFormat != b.format { converter = AVAudioConverter(from: b.format, to: rec16k) }
        guard let converter else { return }
        let cap = AVAudioFrameCount(Double(b.frameLength) * 16000 / b.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: rec16k, frameCapacity: cap) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return b
        }
        if let ch = out.floatChannelData?[0] { samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength))) }
    }
}

/// Junta dois bocados de texto com um espaço.
func joinText(_ a: String, _ b: String) -> String {
    let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
    return a.isEmpty ? b : (b.isEmpty ? a : a + " " + b)
}

func falaLog(_ s: String) {
    #if DEBUG
    print("[Fala] " + s)
    #endif
}
