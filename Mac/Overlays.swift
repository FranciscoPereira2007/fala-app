import SwiftUI
import AppKit
import ServiceManagement

// Definições (modal com sub-tabs), sininho e menu de ajuda, como no Flow.

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "Geral", system = "Sistema", mascot = "Mascote", iphone = "iPhone", account = "Conta", privacy = "Dados e privacidade"
    var id: Self { self }
    var icon: String {
        switch self { case .general: "slider.horizontal.3"; case .system: "laptopcomputer"; case .mascot: "pawprint"; case .iphone: "iphone"; case .account: "person.crop.circle"; case .privacy: "lock.shield" }
    }
}

struct SettingsModal: View {
    let close: () -> Void
    @State var tab: SettingsTab = .general
    @EnvironmentObject var receiver: MacReceiver
    @AppStorage("fala.sounds") private var sounds = true
    @AppStorage("fala.showBar") private var showBar = true
    @AppStorage("fala.muteWhileDictating") private var mute = false
    @AppStorage("fala.contextAware") private var context = true
    @State private var ai: [String: Jarvis.AIAccount] = [:]
    @AppStorage("fala.keepHistory") private var keep = true
    @AppStorage("fala.engine") private var engine = "auto"
    private var engineDetail: String {
        switch engine {
        case "apple": return "Apple SpeechAnalyzer: instantâneo, no Mac, grátis e offline."
        case "legacy": return "Reconhecimento clássico da Apple, no Mac."
        default: return "Texto ao vivo da Apple + Whisper turbo no fim (máxima precisão). Tudo no Mac, grátis e offline."
        }
    }
    @AppStorage("mac.onboarded") private var onboarded = true
    @State private var login = SMAppService.mainApp.status == .enabled
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                section("DEFINIÇÕES"); ForEach([SettingsTab.general, .system, .mascot, .iphone]) { item($0) }
                section("CONTA").padding(.top, 14); ForEach([SettingsTab.account, .privacy]) { item($0) }
                Spacer()
                Text("Fala v1.0").font(.figtree(11)).foregroundStyle(Flow.fg3)
            }
            .padding(12).frame(width: 196).frame(maxHeight: .infinity, alignment: .top).background(Flow.bg3)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(tab.rawValue).font(.garamond(26)).padding(.bottom, 10)
                    content
                }.padding(.horizontal, 34).padding(.vertical, 30).frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Flow.fg3).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).padding(10).keyboardShortcut(.cancelAction)
            }
        }
        .foregroundStyle(Flow.fg).environment(\.colorScheme, .light)
        .frame(width: 760, height: 520)
        .background(Flow.bg).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 25, y: 20)
        .animation(Flow.ease, value: tab)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .general:
            SettingGroup {
                SettingRow(title: "Atalhos", detail: "Segura fn e fala. Clica no pill para mãos livres.") { Button("Alterar") {}.buttonStyle(FlowButton(kind: .beige, small: true)).disabled(true) }
                RowDivider()
                SettingRow(title: "Microfone", detail: "Deteção automática (Microfone)") { Button("Alterar") { openPrefs("com.apple.Sound-Settings.extension") }.buttonStyle(FlowButton(kind: .beige, small: true)) }
                RowDivider()
                SettingRow(title: "Idiomas de ditado", detail: "Português (Portugal)") { Button("Alterar") {}.buttonStyle(FlowButton(kind: .beige, small: true)).disabled(true) }
                RowDivider()
                SettingRow(title: "Transcrição", detail: engineDetail) {
                    Picker("", selection: $engine) {
                        Text("Automático").tag("auto"); Text("Whisper turbo").tag("whisper")
                        Text("Apple (rápido)").tag("apple"); Text("Apple clássico").tag("legacy")
                    }.labelsHidden().frame(width: 150)
                }
            }
        case .mascot:
            MascotPicker()
        case .system:
            label("Definições da app")
            SettingGroup {
                SettingRow(title: "Abrir a app ao iniciar sessão") {
                    FlowToggle(isOn: Binding(get: { login }, set: { v in
                        login = v; try? v ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }))
                }
                RowDivider()
                SettingRow(title: "Mostrar o pill sempre") { FlowToggle(isOn: $showBar) }
                RowDivider()
                SettingRow(title: "Colagem automática", detail: AXIsProcessTrusted() ? "Ativa" : "Precisa de Acessibilidade") {
                    if !AXIsProcessTrusted() { Button("Ativar") { openPrefs("com.apple.preference.security?Privacy_Accessibility") }.buttonStyle(FlowButton(small: true)) }
                }
            }
            label("Som").padding(.top, 10)
            SettingGroup {
                SettingRow(title: "Sons de ditado e notificações") { FlowToggle(isOn: $sounds) }
                RowDivider()
                SettingRow(title: "Silenciar áudio enquanto ditas") { FlowToggle(isOn: $mute) }
            }
            Button("Repetir o onboarding") { onboarded = false; close() }.buttonStyle(FlowButton(kind: .beige, small: true)).padding(.top, 10)
        case .iphone:
            SettingGroup {
                SettingRow(title: "Ligação ao iPhone", detail: receiver.status) {
                    Circle().fill(receiver.status.hasPrefix("À escuta") ? Color(hex: 0x4fbf78) : Color(hex: 0xf9b45c)).frame(width: 9, height: 9)
                }
                RowDivider()
                SettingRow(title: "Como funciona", detail: "Abre a Fala no iPhone, aba Mac. Falas lá e o texto cola aqui, onde estiver o cursor.") { EmptyView() }
            }
        case .account:
            SettingGroup {
                SettingRow(title: "Nome", detail: Me.firstName.isEmpty ? "—" : Me.firstName) { EmptyView() }
                RowDivider()
                SettingRow(title: "Plano", detail: "Grátis para sempre. Tudo corre no teu Mac.") { EmptyView() }
            }
            SettingGroup {
                ForEach(AIAccounts.kinds, id: \.self) { k in
                    let a = ai[k]
                    if k != AIAccounts.kinds[0] { RowDivider() }
                    SettingRow(title: k == "claude" ? "Claude" : "ChatGPT (Codex)",
                               detail: a == nil ? "A ver…" : a!.loggedIn ? "Ligado ✓ · as sessões aparecem no iPhone" : a!.installed ? "Não ligado" : "Não instalado") {
                        Button(a?.loggedIn == true ? "Trocar" : a?.installed == false ? "Instalar" : "Entrar") {
                            AIAccounts.login(k)
                            Task { try? await Task.sleep(for: .seconds(20)); ai = await Task.detached { AIAccounts.status() }.value }
                        }.buttonStyle(FlowButton(kind: .light))
                    }
                }
            }
            .task { ai = await Task.detached { AIAccounts.status() }.value }
        case .privacy:
            SettingGroup {
                SettingRow(title: "Consciência de contexto", detail: "Usa texto relevante da app onde estás a ditar para escrever bem os nomes.") { FlowToggle(isOn: $context) }
                RowDivider()
                SettingRow(title: "Guardar histórico neste Mac", detail: "Os teus ditados nunca saem do Mac. Não há servidores.") { FlowToggle(isOn: $keep) }
            }
        }
    }
    private func section(_ t: String) -> some View { Text(t).font(.figtree(11, weight: 600)).kerning(0.8).foregroundStyle(Flow.fg3).padding(.horizontal, 8).padding(.bottom, 6) }
    private func label(_ t: String) -> some View { Text(t).font(.figtree(14, weight: 600)) }
    private func item(_ t: SettingsTab) -> some View {
        Button { tab = t } label: {
            HStack(spacing: 10) { Image(systemName: t.icon).frame(width: 16); Text(t.rawValue).lineLimit(1) }
                .font(.figtree(14)).padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(tab == t ? Flow.bg2 : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func openPrefs(_ p: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:\(p)")!) }
}

/// Sininho: painel com estado vazio.
struct NotificationsPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notificações").font(.figtree(14, weight: 600)); Spacer()
                Image(systemName: "line.3.horizontal.decrease"); Image(systemName: "ellipsis")
            }.foregroundStyle(Flow.fg).padding(16)
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Flow.bg3).frame(width: 112, height: 112)
                Image(systemName: "binoculars.fill").font(.system(size: 44)).foregroundStyle(Color(hex: 0xff6c4c))
            }
            Text("Está tudo em dia!").font(.figtree(15, weight: 600)).padding(.top, 22)
            Text("Avisamos-te quando houver novidades.").font(.figtree(13)).foregroundStyle(Flow.fg3).padding(.top, 4)
            Spacer()
        }
        .foregroundStyle(Flow.fg).environment(\.colorScheme, .light)
        .frame(width: 360, height: 380)
        .background(Flow.bg)
    }
}

/// Menu de ajuda por cima da sidebar.
struct HelpMenu: View {
    var openSettings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            head("Novidades"); item("info.circle", "O que há de novo") {}; item("iphone", "Experimentar no iPhone") {}
            Divider().padding(.vertical, 6)
            head("Essenciais"); item("command", "Atalhos", openSettings); item("mic", "Microfone", openSettings); item("globe", "Idiomas", openSettings)
        }
        .foregroundStyle(Flow.fg).environment(\.colorScheme, .light)
        .padding(10).frame(width: 200)
    }
    private func head(_ t: String) -> some View { Text(t).font(.figtree(11, weight: 600)).foregroundStyle(Flow.fg3).padding(.horizontal, 6).padding(.vertical, 4) }
    private func item(_ i: String, _ t: String, _ a: @escaping () -> Void) -> some View {
        HoverRow { _ in
            Button(action: a) { HStack(spacing: 8) { Image(systemName: i).frame(width: 16); Text(t) }.font(.figtree(13)).padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }.clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
