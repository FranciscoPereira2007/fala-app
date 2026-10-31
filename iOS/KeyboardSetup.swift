import SwiftUI

/// Ativar o teclado em 3 passos (como o Wispr Flow): o iOS só deixa a pessoa ligar o acesso total nas Definições,
/// por isso abrimos as Definições já na página da Fala e mostramos exatamente onde carregar.
struct KeyboardSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var on = false
    private var enabled: Bool {
        (UITextInputMode.activeInputModes as [UITextInputMode]).contains { ($0.value(forKey: "identifier") as? String)?.contains("com.fran.fala") == true }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                (Text("Ativa o teclado ").font(Theme.garamond(30)) + Text("em 30 segundos").font(Theme.garamond(30, italic: true)).foregroundColor(Theme.orange))
                step(1, "Carrega em Abrir Definições, em baixo.")
                step(2, "Teclados → liga a Fala.")
                step(3, "Liga Permitir acesso total. É o que deixa o teclado abrir a Fala para ouvir.")
                Text("A tua voz é transcrita no teu Mac ou no teu iPhone. Nada é guardado em servidores.")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                Spacer()
                if enabled {
                    Label("Teclado ativo ✓", systemImage: "checkmark.circle.fill").font(Theme.sans(16, .semibold)).foregroundStyle(Theme.forest)
                }
                Button {
                    tick(.medium)
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                } label: {
                    Text("Abrir Definições").font(Theme.sans(17, .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 56).background(Theme.ink, in: Capsule())
                }.buttonStyle(.plain)
            }
            .padding(22)
            .background(Theme.appBG.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Feito") { tick(); dismiss() } } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in on.toggle() }
        }
    }

    private func step(_ n: Int, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(Theme.sans(15, .bold)).foregroundStyle(.white).frame(width: 30, height: 30).background(Theme.orange, in: Circle())
            Text(t).font(Theme.sans(17)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
