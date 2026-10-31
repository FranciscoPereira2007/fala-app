#if os(iOS)
import AppIntents
import Foundation

/// Toque no widget (também no CarPlay): o widget volta a pedir a imagem do Mac.
struct RefreshMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Atualizar ecrã do computador"
    func perform() async throws -> some IntentResult { .result() }
}

/// Botão "Jarvis" do widget: liga à última sessão (chamada do sistema, ouve-se no carro).
/// LiveActivityIntent = corre dentro da app (que acorda em segundo plano), não no widget.
struct CallJarvisIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Ligar ao Jarvis"
    func perform() async throws -> some IntentResult {
        #if FALA_APP
        await MainActor.run { CallCenter.shared.callLast() }
        #endif
        return .result()
    }
}
#endif

#if os(iOS)
// MARK: - Ditado sem abrir a app (Live Activity, Centro de Controlo, Toque atrás)
// LiveActivityIntent = corre dentro da app (viva em segundo plano pelo áudio), não no widget.
// O micro tem de ter sido aberto com a app à frente; depois estes botões mandam na sessão com o ecrã bloqueado.

/// Igual ao certo da aba Ditar: pára, o Mac transcreve com Whisper e cola.
/// Sem ditado a correr: abre a Fala e começa a gravar (o iOS só liga o micro com a app à frente). Toque atrás: 2 toques = começar/enviar.
struct SendDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Enviar ditado"
    static let description = IntentDescription("Envia o que estás a ditar para o computador, como o certo da aba Ditar. Sem ditado, começa um.")
    func perform() async throws -> some IntentResult {
        #if FALA_APP
        let c = await DictationController.shared
        if await c.recording { await c.finish() }
        else { try await startDictation(self, c) }
        #endif
        return .result()
    }
}

/// Pausa sem perder nada; Continuar retoma no mesmo ditado.
struct PauseDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pausar ou continuar ditado"
    func perform() async throws -> some IntentResult {
        #if FALA_APP
        await DictationController.shared.togglePause()
        #endif
        return .result()
    }
}

/// Envia o que já disseste e começa logo outro (o micro não fecha).
struct NewDictationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Novo ditado"
    static let description = IntentDescription("Envia o ditado atual para o computador e começa outro sem parar o micro.")
    func perform() async throws -> some IntentResult {
        #if FALA_APP
        let c = await DictationController.shared
        if await c.recording { await c.finish(again: true) } else { try await startDictation(self, c) }
        #endif
        return .result()
    }
}
#if FALA_APP
// Só na app (nas extensões o iOS não deixa): pedir para continuar com a Fala à frente.
extension SendDictationIntent: ForegroundContinuableIntent {}
extension NewDictationIntent: ForegroundContinuableIntent {}

/// Com a Fala já à frente começa logo; em fundo tenta primeiro (sessão de áudio viva) e só pede "Continuar" se o iOS recusar.
func startDictation<I: ForegroundContinuableIntent>(_ i: I, _ c: DictationController) async throws {
    await c.begin()
    if await c.recording { return }
    try await i.requestToContinueInForeground("Abre a Fala para começar a ditar")
    try? await Task.sleep(for: .milliseconds(400))
    await c.begin()
}
#endif
#endif
