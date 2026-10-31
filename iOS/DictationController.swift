import SwiftUI
import ActivityKit
import Speech
import AVFoundation

/// O ditado da aba Ditar num só sítio, para os botões da Live Activity, do Centro de Controlo e do Toque atrás
/// mandarem nele com a app em segundo plano (FalaIntents: Enviar agora, Pausar/Continuar, Novo).
/// O micro só se abre com a app à frente (regra do iOS); depois a sessão sobrevive em segundo plano entre envios.
@MainActor final class DictationController: ObservableObject {
    static let shared = DictationController()
    @Published var phase: FlowRecorderPanel.Phase = .idle
    @Published var last = ""
    @Published var toast: FlowToast?
    var mic: Transcriber?
    var mac: MacSender?
    var store: Store?
    private var activity: Activity<DictationAttributes>?
    private var started = Date()

    var recording: Bool { mic?.isRecording == true }

    func begin() async {
        guard let mic, !mic.isRecording else { return }
        let ready = SFSpeechRecognizer.authorizationStatus() == .authorized && AVAudioApplication.shared.recordPermission == .granted
        if !ready, !(await mic.authorize()) { toast = FlowToast(text: "Sem acesso ao microfone", ok: false); return }
        mic.keepAudio = true // o Mac transcreve o áudio com Whisper; o SFSpeech é só pré-visualização
        mic.start()
        guard mic.isRecording else { return }
        phase = .listening; started = Date()
        startActivity()
    }

    func cancel() async {
        guard let mic else { return }
        _ = await mic.stop(); mic.keepAudio = false; mic.text = ""; phase = .idle
        await endActivity("fail", "", after: 0)
    }

    /// Pausar/Continuar: continua onde parou (o micro não fecha, o áudio da pausa não entra).
    func togglePause() async {
        guard let mic, mic.isRecording else { return }
        mic.setPaused(!mic.paused)
        phase = mic.paused ? .paused : .listening
        await updateActivity(mic.paused ? "pause" : "rec", "")
    }

    /// Enviar (= o certo da aba Ditar). `again` = Novo: envia o que já disseste e continua a ouvir o seguinte.
    private var finishing = false

    func finish(again: Bool = false, enter: Bool? = nil) async {
        // Reservado antes do 1.º await: dois toques seguidos em Enviar (Live Activity) não colam duas vezes.
        guard let mic, let mac, let store, mic.isRecording, !finishing else { return }
        finishing = true
        var released = false
        func release() { if !released { released = true; finishing = false } }
        defer { release() }
        let autoEnter = enter ?? UserDefaults.standard.bool(forKey: "autoEnter")
        var preview: String, audio: [Float], secs: Double
        if again {
            preview = store.process(mic.fresh); secs = Date().timeIntervalSince(started); started = Date()
            audio = mic.cut()
            release()
            if mic.paused { mic.setPaused(false); phase = .listening }
            await updateActivity("rec", "A enviar o anterior…")
        } else {
            phase = .processing
            await updateActivity("send", "")
            let full = await mic.stop()
            preview = store.process(mic.cutPrefix.isEmpty ? full : mic.fresh) // depois de um "Novo", só o que veio a seguir
            audio = mic.lastAudio; mic.keepAudio = false; secs = Date().timeIntervalSince(started)
        }
        var t = preview, ok = false
        // 1.º: áudio para o Mac (Whisper turbo cola e devolve o texto final). Sem resposta: texto ao vivo.
        if mac.hasMac, audio.count > 8000, let final = await mac.sendAudio(audio, enter: autoEnter, timeout: 12, queueOnFail: true), !final.isEmpty { t = final; ok = true }
        guard !t.isEmpty else { if !again { phase = .idle; await endActivity("fail", "", after: 0) }; return }
        last = t
        UIPasteboard.general.string = t // rede de segurança
        if !ok { ok = await mac.send(t, enter: autoEnter) }
        store.add(t, toMac: ok, seconds: secs)
        toast = ok ? FlowToast(text: "Colado no Mac") : FlowToast(text: mac.pending > 0 ? "Copiado. Vai para o Mac quando ligar (\(mac.pending) na fila)" : (mac.lastError ?? "Abre a Fala no Mac"), ok: false)
        if again {
            await updateActivity("rec", (ok ? "Colado: " : "Na fila: ") + String(t.prefix(60)))
            return
        }
        phase = .done(ok ? "Enviado para o Mac 🎉" : "Copiado, o Mac não respondeu")
        await endActivity(ok ? "done" : "fail", t, after: 4)
        try? await Task.sleep(for: .seconds(2.2))
        if case .done = phase { phase = .idle }
    }

    // MARK: Live Activity com os botões (ecrã bloqueado e notificações)

    private func startActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for a in Activity<DictationAttributes>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } }
        activity = try? Activity.request(attributes: DictationAttributes(), content: .init(state: .init(phase: "rec", text: "", started: started), staleDate: nil))
    }
    private func updateActivity(_ phase: String, _ text: String) async {
        guard let a = activity else { return }
        await a.update(.init(state: .init(phase: phase, text: text, started: started), staleDate: nil))
    }
    private func endActivity(_ phase: String, _ text: String, after: Double) async {
        guard let a = activity else { return }
        activity = nil
        await a.end(.init(state: .init(phase: phase, text: String(text.prefix(80)), started: started), staleDate: nil),
                    dismissalPolicy: after > 0 ? .after(Date().addingTimeInterval(after)) : .immediate)
    }
}
