import AppIntents
import Foundation

extension Notification.Name { static let falaToggle = Notification.Name("fala.toggleDictation") }

/// "Ditar para o computador": botão de ação, toque atrás, Siri, Atalhos ou ecrã bloqueado.
/// 1.º toque abre a Fala na aba Mac e começa a gravar; 2.º toque pára e cola no Mac.
/// Com o modo de áudio em segundo plano, a gravação continua com o ecrã bloqueado.
struct DictateToMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Ditar para o computador"
    static let description = IntentDescription("Começa ou termina um ditado que cola no computador.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        try? await Task.sleep(for: .milliseconds(350)) // a app acabou de abrir: deixa a vista montar
        NotificationCenter.default.post(name: .falaToggle, object: nil)
        return .result()
    }
}

struct FalaShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DictateToMacIntent(), phrases: ["Ditar para o computador com a \(.applicationName)", "\(.applicationName) ditar"],
                    shortTitle: "Ditar para o computador", systemImageName: "mic.fill")
        AppShortcut(intent: MacDictateIntent(), phrases: ["Ditar sem sair com a \(.applicationName)"],
                    shortTitle: "Ditar sem sair", systemImageName: "waveform")
        // Toque atrás (Acessibilidade > Toque > Toque atrás): 2 toques = Enviar, 3 toques = Novo.
        AppShortcut(intent: SendDictationIntent(), phrases: ["Enviar ditado da \(.applicationName)"], shortTitle: "Enviar ditado", systemImageName: "checkmark.circle")
        AppShortcut(intent: NewDictationIntent(), phrases: ["Novo ditado da \(.applicationName)"], shortTitle: "Novo ditado", systemImageName: "plus.circle")
        AppShortcut(intent: PauseDictationIntent(), phrases: ["Pausar ditado da \(.applicationName)"], shortTitle: "Pausar ou continuar", systemImageName: "pause.circle")
    }
}

