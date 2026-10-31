import Foundation
import ActivityKit
import AppIntents
import AVFoundation

/// Ditar sem abrir a app (botão de ação, Atalhos, Siri, ecrã bloqueado): 1.º toque grava, 2.º envia para o Mac.
@MainActor enum LockDictation {
    static var mic: Transcriber?
    static var mac: MacSender?
    static var store: Store?
    private static var activity: Activity<DictationAttributes>?

    static func toggle() async -> String {
        let mic = mic ?? { let m = Transcriber(); Self.mic = m; return m }()
        let mac = mac ?? { let m = MacSender(); Self.mac = m; return m }()
        if !mic.isRecording {
            var allowed = AVAudioApplication.shared.recordPermission == .granted
            if !allowed { allowed = await mic.authorize() }
            guard allowed else { return "Sem acesso ao microfone. Abre a Fala uma vez." }
            mic.keepAudio = true; mic.start()
            guard mic.isRecording else { return "Não consegui gravar." }
            await start()
            return "A ouvir. Toca outra vez para enviar."
        }
        await update("send", "")
        let preview = await mic.stop()
        let audio = mic.lastAudio; mic.keepAudio = false
        var text = preview, ok = false
        if audio.count > 8000, let t = await mac.sendAudio(audio, enter: false, timeout: 15, queueOnFail: true), !t.isEmpty { text = t; ok = true }
        if !ok, !text.isEmpty { ok = await mac.send(text, enter: false) }
        if !text.isEmpty { store?.add(text, toMac: ok, seconds: mic.seconds) }
        await finish(ok ? "done" : "fail", text)
        return ok ? "Colado no Mac." : (mac.pending > 0 ? "Guardado, vai para o Mac quando ligar." : "O Mac não respondeu.")
    }

    private static func start() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        activity = try? Activity.request(attributes: DictationAttributes(), content: .init(state: .init(phase: "rec", text: "", started: Date()), staleDate: nil))
    }
    private static func update(_ phase: String, _ text: String) async {
        guard let a = activity else { return }
        await a.update(.init(state: .init(phase: phase, text: text, started: a.content.state.started), staleDate: nil))
    }
    private static func finish(_ phase: String, _ text: String) async {
        guard let a = activity else { return }
        await a.end(.init(state: .init(phase: phase, text: String(text.prefix(80)), started: a.content.state.started), staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(4)))
        activity = nil
    }
}

// ponytail: o intent "sem abrir" (AudioRecordingIntent) faz o iOS 26 abortar a app antes do perform (assertion
// nas AppIntents, sem mensagem legível sem logs de root). LiveActivityIntent não deixa abrir o microfone em
// segundo plano. Fica o LockDictation + Live Activity prontos; religar quando houver a mensagem do sistema.
