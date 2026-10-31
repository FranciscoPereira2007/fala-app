import AVFoundation
import Speech
import UIKit

/// "Fala ligada" para o teclado (como o "Flow is on" do Wispr): a app mantém o microfone aberto em segundo plano
/// e grava quando o teclado pede, sem sair da app onde estás. Fica ligada até a desligares (☰ no teclado).
@MainActor final class KeyboardSession {
    static let shared = KeyboardSession()
    var mac: MacSender?
    var store: Store?
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var capturing = false
    private var samples: [Float] = []
    private var running = false
    private var idleTimer: Timer?
    // Pré-visualização ao vivo (Apple, no iPhone, grátis); o Whisper do Mac dá o texto final.
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "pt-PT"))
    private var live: SFSpeechAudioBufferRecognitionRequest?
    private var liveTask: SFSpeechRecognitionTask?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    private init() {
        KeyboardBridge.serve { cmd in MainActor.assumeIsolated {
            let me = KeyboardSession.shared
            switch cmd {
            case "start": me.begin()
            case "stop": me.current(phase: "processing"); Task { await me.finish() }
            case "cancel": me.cancel()
            case "off": me.stop()
            case "ack": if KeyboardBridge.current.phase == "done" { me.set(phase: "idle", text: "") }
            default: break
            }
        } }
    }

    var isOn: Bool { running }

    /// Liga a sessão (vem do botão Start do teclado, por fala://start).
    func start() {
        guard !running else { touch(); return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try s.setActive(true)
            if let builtIn = s.availableInputs?.first(where: { $0.portType == .builtInMic }) { try? s.setPreferredInput(builtIn) }
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            converter = AVAudioConverter(from: fmt, to: target)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1600, format: fmt) { [weak self] buf, _ in self?.feed(buf) }
            try engine.start()
            running = true
            set(phase: "idle", text: "")
            touch()
        } catch {
            set(phase: "error", text: "Não consegui abrir o microfone")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        running = false; capturing = false; idleTimer?.invalidate()
        set(phase: "idle", text: "")
    }

    private func touch() {
        idleTimer?.invalidate()
        // Fica ligada até a desligares (☰ no teclado); só se apaga sozinha após 3 h sem ditados, para poupar bateria.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: false) { _ in Task { @MainActor in KeyboardSession.shared.stop() } }
    }

    nonisolated private func feed(_ buf: AVAudioPCMBuffer) {
        Task { @MainActor in self.ingest(buf) }
    }

    private func ingest(_ buf: AVAudioPCMBuffer) {
        guard capturing, let converter else { return }
        live?.append(buf)
        let ratio = 16000 / buf.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32) else { return }
        var used = false
        converter.convert(to: out, error: nil) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true; status.pointee = .haveData; return buf
        }
        guard let p = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        samples += chunk
        // Nível para a onda do teclado: mesma fórmula da app (Transcriber).
        if !chunk.isEmpty { KeyboardBridge.current.level = min(1, sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)) * 20) }
    }

    fileprivate func begin() {
        guard running else { set(phase: "error", text: "Liga a Fala primeiro (Start)"); return }
        samples = []; capturing = true; touch()
        set(phase: "listening", text: "")
        startLive()
    }

    fileprivate func cancel() { stopLive(); capturing = false; samples = []; set(phase: "idle", text: "") }

    private func startLive() {
        stopLive()
        guard let recognizer, recognizer.isAvailable, SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        r.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
        live = r
        liveTask = recognizer.recognitionTask(with: r) { [weak self] res, _ in
            guard let t = res?.bestTranscription.formattedString else { return }
            Task { @MainActor in
                guard let self, self.capturing, KeyboardBridge.current.phase == "listening" else { return }
                KeyboardBridge.current.text = t
            }
        }
    }
    private func stopLive() { live?.endAudio(); liveTask?.cancel(); live = nil; liveTask = nil }

    /// Toque atrás / atalho, sem sair da app: 1.º toque grava, 2.º cola onde estiver o cursor no Mac.
    private var forMac = false
    func toggleForMac() async -> String {
        guard running else { return "Liga a Fala primeiro (Start no teclado ou na app)." }
        if !capturing { forMac = true; begin(); return "A ouvir. Toca outra vez para colar no Mac." }
        capturing = false; touch(); stopLive()
        let audio = samples; samples = []; forMac = false
        guard audio.count > 8000 else { set(phase: "idle", text: ""); return "Não ouvi nada." }
        set(phase: "processing", text: "")
        if let mac, let t = await mac.sendAudio(audio, enter: false, paste: true, timeout: 15, queueOnFail: true), !t.isEmpty {
            store?.add(t, toMac: true, seconds: Double(audio.count) / 16000); set(phase: "idle", text: ""); return "Colado no Mac."
        }
        set(phase: "idle", text: ""); return mac?.lastError ?? "Guardado; vai para o Mac quando ligar."
    }

    fileprivate func finish() async {
        guard capturing else { return }
        capturing = false; touch(); stopLive()
        let audio = samples; samples = []
        guard audio.count > 8000 else { set(phase: "idle", text: ""); return }
        set(phase: "processing", text: "")
        if let mac, let t = await mac.sendAudio(audio, enter: false, paste: false, timeout: 15), !t.isEmpty {
            store?.add(t, toMac: false, seconds: Double(audio.count) / 16000)
            set(phase: "done", text: t)
        } else {
            set(phase: "error", text: mac?.lastError ?? "O Mac não respondeu")
        }
    }

    fileprivate func set(phase: String, text: String) {
        KeyboardBridge.current = .init(phase: phase, text: text, level: 0, session: running, at: Date().timeIntervalSince1970)
    }
    /// Resposta imediata ao "stop" (a transcrição corre depois).
    fileprivate func current(phase: String) { if capturing { KeyboardBridge.current.phase = phase } }
}

import SwiftUI
/// Depois do Start: a Fala fica ligada; volta à app onde estavas (◀ no canto superior esquerdo).
struct SessionOnView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.orange)
                .symbolEffect(.variableColor.iterative)
            (Text("A Fala está ").font(Theme.garamond(30)) + Text("ligada").font(Theme.garamond(30, italic: true)).foregroundColor(Theme.orange))
            Text("Volta à app onde estavas: toca em ◀ no canto superior esquerdo. A partir de agora ditas sem sair dela.")
                .font(Theme.sans(16)).multilineTextAlignment(.center).foregroundStyle(Theme.ink.opacity(0.75))
            Text("Fica ligada até a desligares no ☰ do teclado.").font(Theme.sans(13)).foregroundStyle(Theme.muted)
        }
        .padding(28).presentationDetents([.medium])
        .task { try? await Task.sleep(for: .seconds(6)); dismiss() }
    }
}

import AppIntents
/// "Ditar para o Mac" sem abrir a Fala (precisa da Fala ligada): para o toque atrás, botão de ação ou Atalhos.
struct MacDictateIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Ditar para o computador (Fala ligada)"
    static let description = IntentDescription("Com a Fala ligada: 1.º toque grava, 2.º cola no computador. Não sai da app onde estás.")
    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(await KeyboardSession.shared.toggleForMac(), forKey: "fala.lastIntent")
        return .result()
    }
}
