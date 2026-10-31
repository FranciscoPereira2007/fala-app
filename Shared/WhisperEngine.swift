#if canImport(WhisperKit)
import Foundation
import WhisperKit

/// Whisper local (WhisperKit, CoreML/Neural Engine). Grátis: o modelo descarrega-se uma vez do
/// Hugging Face e corre tudo no aparelho. Transcreve o áudio completo no fim do ditado.
final class WhisperEngine: @unchecked Sendable {
    static let shared = WhisperEngine()

    /// Modelo por aparelho (mudável em "fala.whisperModel").
    static var modelName: String {
        if let m = UserDefaults.standard.string(forKey: "fala.whisperModel"), !m.isEmpty { return m }
        #if os(macOS)
        return "openai_whisper-large-v3-v20240930_turbo_632MB"
        #else
        return "openai_whisper-base"
        #endif
    }

    static var downloadBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        return base.appendingPathComponent("Fala/whisperkit") // partilhado com o benchmark
        #else
        return base.appendingPathComponent("whisperkit")
        #endif
    }

    static var modelFolder: URL {
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelName)")
    }

    /// Nomes próprios para orientar o Whisper (dicionário do utilizador entra aqui).
    /// Vem das preferências de cada utilizador ("fala.vocabulary"), nada fixo no código.
    var vocabulary: [String] = UserDefaults.standard.stringArray(forKey: "fala.vocabulary") ?? []

    private let lock = NSLock()
    private var kit: WhisperKit?
    private var loading: Task<WhisperKit?, Never>?
    private(set) var lastError: String?

    init(modelFolder: URL? = nil) { if let modelFolder { explicitFolder = modelFolder } }
    private var explicitFolder: URL?

    /// Modelo já descarregado (não bloqueia o arranque do ditado à espera de rede).
    var isReady: Bool {
        return lock.withLock { kit != nil }
    }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: (explicitFolder ?? Self.modelFolder).appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    /// Carrega (e descarrega na 1.ª vez) em segundo plano.
    func warmUp() {
        #if os(macOS)
        // Com o PC ligado não carregamos o modelo (1,6 GB de RAM e calor); carrega-se só se o PC falhar.
        Task { if await !PCNode.isUp() { _ = self.loadTask() } }
        #else
        _ = loadTask()
        #endif
    }

    private func loadTask() -> Task<WhisperKit?, Never> {
        lock.lock(); defer { lock.unlock() }
        if let loading { return loading }
        let folder = explicitFolder
        let t = Task.detached(priority: .utility) { [weak self] () -> WhisperKit? in
            do {
                let cfg: WhisperKitConfig
                if let folder {
                    cfg = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Self.downloadBase, verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
                } else if FileManager.default.fileExists(atPath: Self.modelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                    cfg = WhisperKitConfig(modelFolder: Self.modelFolder.path, tokenizerFolder: Self.downloadBase, verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
                } else {
                    cfg = WhisperKitConfig(model: Self.modelName, downloadBase: Self.downloadBase, tokenizerFolder: Self.downloadBase, verbose: false, logLevel: .error, prewarm: true, load: true, download: true)
                }
                let k = try await WhisperKit(cfg)
                self?.lock.withLock { self?.kit = k }
                return k
            } catch {
                // Modelo gerido pela app e corrompido (download interrompido): apaga para voltar a descarregar.
                if folder == nil { try? FileManager.default.removeItem(at: Self.modelFolder) }
                self?.lock.withLock { self?.lastError = "\(error)"; self?.loading = nil }
                return nil
            }
        }
        loading = t
        return t
    }

    /// Ganho automático: o micro do MacBook (e o do Poco) chega muito mais baixo do que o do iPhone, e o filtro de silêncio
    /// (RMS 0,002) e o VAD tratavam voz fraca como silêncio (frases inteiras perdidas). Leva a voz a ~-22 dBFS sem saturar;
    /// silêncio e áudio já forte ficam iguais. Medido no research/stt-benchmark (voz baixa: WER 10,5% -> 9,8%).
    static func normalized(_ s: [Float], target: Float = 0.08, maxGain: Float = 40) -> [Float] {
        let n = s.count / 320
        guard n > 4 else { return s }
        let frames = (0..<n).map { f in s[(f * 320)..<(f * 320 + 320)].reduce(Float(0)) { $0 + $1 * $1 } / 320 }.sorted(by: >)
        let top = frames.prefix(max(1, n * 3 / 10))
        let rms = sqrt(top.reduce(0, +) / Float(top.count))
        let peak = s.reduce(Float(0)) { max($0, abs($1)) }
        guard rms >= 0.0003, peak > 0 else { return s }
        let g = min(target / rms, 0.97 / peak, maxGain)
        return g <= 1.05 ? s : s.map { $0 * g }
    }

    /// Transcreve 16 kHz mono. Devolve nil se o modelo não estiver pronto.
    func transcribe(_ input: [Float], waitForModel: Bool = false, prompt: Bool = true) async -> String? {
        guard input.count > 8000 else { return "" } // < 0,5 s
        let samples = Self.normalized(input)
        #if os(macOS)
        // 1.º o PC com GPU (o MacBook não aquece); sem PC, o Whisper local como sempre.
        let dict0 = (UserDefaults.standard.dictionary(forKey: "fala.dict") as? [String: String]).map { Array($0.values) } ?? []
        if let t = await PCNode.transcribe(samples, prompt: Array(NSOrderedSet(array: vocabulary + dict0 + TextCleanup.techTerms).array as? [String] ?? []).prefix(40).joined(separator: ", ")) {
            return Self.scrub(t)
        }
        UserDefaults.standard.set("Mac", forKey: "fala.sttRoute")
        #endif
        let k: WhisperKit?
        if waitForModel { k = await loadTask().value } else { k = lock.withLock { kit } }
        guard let k else { warmUp(); return nil }
        // Silêncio: o Whisper inventa ("Legendas pela comunidade Amara.org"); não lhe damos a hipótese.
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > 0.002 else { return "" }
        var opts = DecodingOptions(task: .transcribe, language: "pt", temperature: 0, temperatureFallbackCount: 2,
                                   usePrefillPrompt: true, detectLanguage: false, skipSpecialTokens: true,
                                   withoutTimestamps: true, suppressBlank: true, chunkingStrategy: .vad)
        // Vocabulário + palavras certas do dicionário do utilizador (máx. ~40 para não pesar no prompt).
        let dict = (UserDefaults.standard.dictionary(forKey: "fala.dict") as? [String: String]).map { Array($0.values) } ?? []
        let words = Array(NSOrderedSet(array: vocabulary + dict + TextCleanup.techTerms).array as? [String] ?? vocabulary).prefix(40)
        if prompt, let tok = k.tokenizer, !words.isEmpty {
            let ids = tok.encode(text: " " + words.joined(separator: ", ") + ".")
            opts.promptTokens = ids.filter { $0 < tok.specialTokens.specialTokenBegin }
        }
        do {
            let t0 = Date()
            let res = try await k.transcribe(audioArray: samples, decodeOptions: opts)
            // Diagnóstico do último ditado (lido com `defaults read com.fran.fala.mac fala.whisperDiag`).
            let diag = res.flatMap(\.segments).map { String(format: "[ns %.2f lp %.2f cr %.2f t %.1f] %@", $0.noSpeechProb, $0.avgLogprob, $0.compressionRatio, $0.temperature, $0.text) }
            UserDefaults.standard.set("rms \(rms) n \(samples.count) \(Date().timeIntervalSince(t0))s\n" + diag.joined(separator: "\n"), forKey: "fala.whisperDiag")
            // Só segmentos com fala: o Whisper inventa frases nos silêncios entre blocos.
            let segs = res.flatMap(\.segments).filter { sg in
                let words = Self.scrub(sg.text).split(separator: " ").count
                if sg.noSpeechProb > 0.6 && sg.avgLogprob < -0.5 { return false }
                if words <= 2 && (sg.avgLogprob < -0.8 || sg.noSpeechProb > 0.3) { return false }
                return sg.compressionRatio < 2.6
            }
            let text = segs.isEmpty && res.flatMap(\.segments).isEmpty ? res.map(\.text).joined(separator: " ") : segs.map(\.text).joined(separator: " ")
            return Self.scrub(text)
        } catch {
            lock.withLock { lastError = "\(error)" }
            return nil
        }
    }

    /// Tira tokens especiais e alucinações típicas do Whisper em pt.
    static func scrub(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
        for h in ["Legendas pela comunidade Amara.org", "Legendas pela comunidade de Amara.org", "Obrigado por assistir", "Inscreva-se no canal", "Subtítulos realizados por la comunidad de Amara.org", "Transcription by CastingsWords", "Transcrição por CastingsWords", "Legendas por"] {
            t = t.replacingOccurrences(of: h, with: "", options: .caseInsensitive)
        }
        return t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
