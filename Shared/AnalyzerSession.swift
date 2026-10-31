import Foundation
import Speech
import AVFoundation

/// Motor novo da Apple (iOS/macOS 26): SpeechAnalyzer + SpeechTranscriber, on-device, grátis.
/// Cada resultado final é um segmento fechado e acumula-se; o volátil é só o bocado em curso.
/// Assim uma pausa nunca apaga o que já foi dito (era o bug do "Bom dia").
@available(iOS 26.0, macOS 26.0, *)
final class AnalyzerSession: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>
    private let cont: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var results: Task<Void, Never>?
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""

    static let locale = Locale(identifier: "pt-PT")

    /// Disponível neste aparelho e com o modelo pt-PT instalado (descarrega-o uma vez se faltar).
    static func prepare() async -> Bool {
        falaLog("SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable)")
        guard SpeechTranscriber.isAvailable,
              let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
        falaLog("estado do modelo \(loc.identifier): \(await AssetInventory.status(forModules: [SpeechTranscriber(locale: loc, preset: .progressiveTranscription)]))")
        let t = SpeechTranscriber(locale: loc, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [t]) == .installed { return true }
        do {
            try await AssetInventory.reserve(locale: loc)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await req.downloadAndInstall() }
        } catch { falaLog("download do modelo falhou: \(error)"); return false }
        return await AssetInventory.status(forModules: [t]) == .installed
    }

    private init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat) {
        self.analyzer = analyzer; self.transcriber = transcriber; self.format = format
        (input, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    static func start(onUpdate: @escaping @Sendable (_ finalized: String, _ volatile: String) -> Void) async throws -> AnalyzerSession {
        let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let t = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                  reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        let a = SpeechAnalyzer(modules: [t], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { throw CocoaError(.featureUnsupported) }
        let s = AnalyzerSession(analyzer: a, transcriber: t, format: f)
        s.results = Task {
            do {
                for try await r in t.results {
                    let txt = String(r.text.characters)
                    falaLog("resultado final=\(r.isFinal): \(txt)")
                    s.lock.lock()
                    if r.isFinal { s.finalized = Self.join(s.finalized, txt); s.volatile = "" } else { s.volatile = txt }
                    let (fi, vo) = (s.finalized, s.volatile)
                    s.lock.unlock()
                    onUpdate(fi, vo)
                }
            } catch {}
        }
        try await a.start(inputSequence: s.input)
        return s
    }

    /// Chamado na thread de áudio: converte para o formato do modelo e envia.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if buffer.format == format { cont.yield(AnalyzerInput(buffer: buffer)); return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }

    /// Fecha o áudio e espera pelos últimos resultados finais (máx. `timeout`).
    func finish(timeout: Double = 4) async -> String {
        cont.finish()
        let a = analyzer, r = results, flag = DoneFlag()
        Task { try? await a.finalizeAndFinishThroughEndOfInput(); await r?.value; flag.set() }
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.isSet, Date() < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        lock.lock(); defer { lock.unlock() }
        return Self.join(finalized, volatile)
    }

    func cancel() { cont.finish(); let a = analyzer; Task { await a.cancelAndFinishNow() }; results?.cancel() }

    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? b : (b.isEmpty ? a : a + " " + b)
    }
}

final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
