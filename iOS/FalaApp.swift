import SwiftUI
import UIKit
import Speech
import AVFoundation

@main struct FalaApp: App {
    @UIApplicationDelegateAdaptor(FalaAppDelegate.self) private var delegate
    @StateObject private var store = Store()
    @StateObject private var mic = Transcriber()
    @StateObject private var mac = MacSender()
    @StateObject private var jarvis = JarvisModel()
    @ObservedObject private var calls = CallCenter.shared
    @AppStorage("onboarded.v2") private var onboarded = false
    @AppStorage("fala.loginSkipped") private var loginSkipped = false
    @ObservedObject private var account = FalaAccount.shared
    @State private var fromKeyboard = false
    @State private var sessionStarted = false

    var body: some Scene {
        WindowGroup {
            Group {
                // iPad: coluna centrada e legível (no iPhone não muda nada); o onboarding pinta o próprio fundo à largura toda.
                if !account.signedIn && !loginSkipped { LoginView { withAnimation { loginSkipped = true } }.ipadColumn() }
                else if onboarded { RootTabs().ipadColumn() } else { Onboarding { withAnimation { onboarded = true } } }
            }
                .environmentObject(store).environmentObject(mic).environmentObject(mac).environmentObject(jarvis)
                .tint(Theme.ink).preferredColorScheme(.light)
                .font(Theme.sans(17)).environment(\.legibilityWeight, .regular)
                .onAppear { if MacSender.paired { MacSender.token = MacSender.token; MacSender.host = MacSender.host } // copia para o widget (CarPlay)
                    mac.startBrowsing(); LockDictation.mic = mic; LockDictation.mac = mac; LockDictation.store = store
                    DictationController.shared.mic = mic; DictationController.shared.mac = mac; DictationController.shared.store = store
                    KeyboardSession.shared.mac = mac; KeyboardSession.shared.store = store }
                .sheet(isPresented: $sessionStarted) { SessionOnView() }
                // Chamada ao Jarvis: ecrã inteiro, ou minimizada numa barra verde no topo (continua a correr).
                .overlay(alignment: .top) { CallPill().environmentObject(jarvis) }
                .fullScreenCover(isPresented: $calls.shown) {
                    if let m = calls.model { CallView(call: m).environmentObject(mac).environmentObject(jarvis) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in Task { await mac.flush() } }
                .onOpenURL { url in
                    if url.host == "record" { fromKeyboard = true }
                    if url.host == "start" { KeyboardSession.shared.start(); sessionStarted = true }
                    if url.host == "pair", let kind = Pairing.apply(url.absoluteString) {
                        Task { if kind == .mac { _ = await mac.ping(timeout: 10); await mac.flush() }; await FalaAccount.shared.push() }
                    }
                }
                .fullScreenCover(isPresented: $fromKeyboard) {
                    KeyboardRecordView { fromKeyboard = false }.environmentObject(store).environmentObject(mic)
                }
        }
    }
}

extension View {
    func ipadColumn() -> some View { frame(maxWidth: 760).mask(Rectangle().ignoresSafeArea()) /* corta só dos lados: .clipped() cortava também a zona da barra do iPhone e as caixas de texto não desciam */.frame(maxWidth: .infinity).background(Theme.appBG.ignoresSafeArea()) }
}

// MARK: - Tabs com barra flutuante (como o Flow), mais a aba Mac.
enum AppTab: String, CaseIterable { case home = "Home", mac = "Ditar", sessions = "Sessões", control = "Controlar"
    var icon: String { switch self { case .home: "house"; case .mac: "mic"; case .sessions: "terminal"; case .control: "display" } }
}

struct RootTabs: View {
    @State private var tab: AppTab = AppTab(rawValue: UserDefaults.standard.string(forKey: "fala.startTab") ?? "") ?? .home // ponytail: -fala.startTab Sessões (testes no simulador)
    @State private var menu = false
    @ObservedObject private var ctl = DictationController.shared
    @EnvironmentObject var jarvis: JarvisModel
    @Namespace private var ns
    var body: some View {
        ZStack(alignment: .bottom) {
            // As abas em páginas: arrastar para o lado mostra logo a aba seguinte a acompanhar o dedo.
            // Dentro de uma conversa (ou com o menu aberto) o arrasto não muda de aba.
            TabView(selection: $tab) {
                HomeView(go: { t in withAnimation(.snappy(duration: 0.25)) { tab = t } }, menu: $menu).tag(AppTab.home)
                DictateView().tag(AppTab.mac)
                SessionsView().tag(AppTab.sessions)
                ControlView().tag(AppTab.control)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Toque atrás / Centro de Controlo começou a ditar: mostra o painel do Ditar.
            .onChange(of: ctl.recording) { _, on in if on { menu = false; tab = .mac } }
            .scrollDisabled(menu) // ponytail: com o chat aberto não: no iOS 26 desliga o pan de todos os ScrollViews filhos (o .scrollDisabled(false) deles não chega)
            .background(Theme.appBG.ignoresSafeArea())
            .ignoresSafeArea(.container, edges: .bottom)
            .onChange(of: tab) { _, _ in tick() }
            if !jarvis.chatOpen { tabBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            SideMenu(open: $menu)
        }
    }

    // Pill #F6F6F8 com cápsula ativa #E3E3E5 que desliza (mola) e ícone ativo roxo.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { t in
                Button { withAnimation(.spring(duration: 0.32, bounce: 0.18)) { tab = t } } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 18, weight: tab == t ? .semibold : .regular))
                            .foregroundStyle(tab == t ? Theme.tabPurple : Theme.ink)
                            .symbolEffect(.bounce.down, value: tab == t)
                            .overlay(alignment: .topTrailing) {
                                // /dopamina: pendente verdadeiro (sessões à tua espera), nunca inventado.
                                let n = t == .sessions ? jarvis.sessions.filter(\.needsYou).count : 0
                                if n > 0 {
                                    Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                        .frame(minWidth: 16, minHeight: 16).background(Theme.orange, in: Circle()).offset(x: 10, y: -6)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                        Text(LocalizedStringKey(t.rawValue)).font(Theme.sans(11, .medium)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .background { if tab == t { Capsule().fill(Theme.tabActive).matchedGeometryEffect(id: "pill", in: ns) } }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(Theme.tabPill.opacity(0.92), in: Capsule())
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 12, y: 2)
        .padding(.horizontal, 21).padding(.bottom, 2)
        .sensoryFeedback(.selection, trigger: tab)
        .animation(.spring(duration: 0.3), value: jarvis.chatOpen)
        .onReceive(NotificationCenter.default.publisher(for: .falaToggle)) { _ in if tab != .mac { tab = .mac; Task { try? await Task.sleep(for: .milliseconds(300)); NotificationCenter.default.post(name: .falaToggle, object: nil) } } }
    }
}

// MARK: - Home
struct HomeView: View {
    var go: (AppTab) -> Void
    @Binding var menu: Bool
    @EnvironmentObject var store: Store
    @EnvironmentObject var mac: MacSender
    @AppStorage("home.banner") private var showBanner = true
    @State private var toast: FlowToast?
    var body: some View {
        VStack(spacing: 0) {
            FlowHeader(menu: { withAnimation(.spring(duration: 0.38, bounce: 0.08)) { menu = true } }) { FalaLogo() } trailing: {
                Button { tick();
                    toast = mac.macName == nil ? FlowToast(text: "Mac não encontrado", ok: false) : FlowToast(text: "Mac ligado")
                } label: {
                    Image(systemName: "laptopcomputer").font(Theme.sans(17, .semibold))
                        .foregroundStyle(mac.macName == nil ? Theme.ink.opacity(0.45) : Theme.green)
                        .frame(width: 48, height: 48)
                        .background(mac.macName == nil ? Color.black.opacity(0.06) : Theme.greenSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .animation(.spring(duration: 0.3), value: mac.macName)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if showBanner {
                        FlowBanner(title: { Text("Fala no iPhone, ") + Text("escreve no Mac").italic() },
                                   bodyText: Text("Usa a tua voz para escrever emails, mensagens e notas. Na aba Mac, o texto cola onde estiver o cursor."),
                                   cta: "Experimentar", ctaStyle: .capsule, action: { go(.mac) },
                                   close: { withAnimation(.spring(duration: 0.35)) { showBanner = false } })
                    }
                    let today = store.entries.filter { Calendar.current.isDateInToday($0.date) }
                    HStack(spacing: 6) { Text("Hoje"); Image(systemName: "info.circle") }
                        .font(Theme.sans(16)).foregroundStyle(Theme.ink.opacity(0.6)).padding(.leading, 2).padding(.top, 6)
                    if today.isEmpty {
                        Text("Ainda nada hoje. Toca em Mac e diz a tua primeira frase.").font(Theme.sans(16))
                            .foregroundStyle(Theme.muted).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(today) { e in
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(e.text).font(Theme.sans(16)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 6) { Text(e.date.formatted(date: .omitted, time: .shortened)); if e.toMac { Image(systemName: "laptopcomputer") } }
                                        .font(Theme.sans(13)).foregroundStyle(Theme.ink.opacity(0.45))
                                }
                                .padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .contextMenu { Button("Copiar", systemImage: "doc.on.doc") { tick(); UIPasteboard.general.string = e.text; toast = FlowToast(text: "Copiado") } }
                                if e.id != today.last?.id { Divider() }
                            }
                        }
                        .padding(.horizontal, 18)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 100)
                .animation(.spring(duration: 0.4), value: store.entries.count)
            }
        }
        .flowToast($toast, top: 66)
    }
}

/// O "menu" do Flow: conta, palavras e WPM.
struct StatsSheet: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FalaLogo().foregroundStyle(Theme.ink).padding(.top, 8)
            Text("\(store.totalWords.formatted()) palavras · \(store.wpm) WPM").font(Theme.sans(15)).foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                stat("\(store.totalWords.formatted())", "palavras ditas", Theme.forest)
                stat("\(store.streak) 🔥", store.streak == 1 ? "dia seguido" : "dias seguidos", Theme.orange)
            }
            stat("\(store.minutesSaved) min", "poupados a escrever", Theme.forest)
            Spacer()
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Theme.appBG)
    }
    func stat(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(v).font(Theme.garamond(30)).foregroundStyle(c); Text(l).font(Theme.sans(14)).foregroundStyle(Theme.muted) }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Mac (a aba nova): fala aqui, cola no Mac. Painel igual ao teclado Flow.
struct DictateView: View {
    @State private var pairing = false
    @EnvironmentObject var mic: Transcriber
    @EnvironmentObject var store: Store
    @EnvironmentObject var mac: MacSender
    @ObservedObject private var ctl = DictationController.shared
    @AppStorage("autoEnter") private var autoEnter = false
    @AppStorage("fala.dest") private var dest = "Mac" // "Mac" | "PC"
    private var toPC: Bool { dest == "PC" }
    @State private var pcPhase: FlowRecorderPanel.Phase = .idle
    @State private var pcLast = ""
    @State private var toast: FlowToast?
    private var phase: FlowRecorderPanel.Phase { toPC ? pcPhase : ctl.phase }
    private var last: String { toPC ? pcLast : ctl.last }

    var body: some View {
        VStack(spacing: 0) {
            FlowHeader { Text(dest).font(Theme.sans(18, .medium)) } trailing: {
                Circle().fill(toPC || mac.hasMac ? Theme.green : Theme.disabled).frame(width: 9, height: 9).frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 14) {
                Picker("Destino", selection: $dest) { Text("Mac").tag("Mac"); Text("PC").tag("PC") }
                    .pickerStyle(.segmented).disabled(mic.isRecording)
                (Text("Fala aqui, ").font(Theme.garamond(30)) + Text("aparece no \(dest)").font(Theme.garamond(30, italic: true)).foregroundColor(Theme.orange))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 4)
                if toPC {
                    Label("Cola na janela ativa do PC", systemImage: "pc").font(Theme.sans(13)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                } else {
                    Label(mac.paired || Demo.on ? mac.label : "Toca para ligar ao Mac (QR)", systemImage: !mac.hasMac ? "wifi.exclamationmark" : "checkmark.circle.fill")
                        .font(Theme.sans(13)).foregroundStyle(!mac.hasMac ? Theme.muted : Theme.forest).frame(maxWidth: .infinity)
                        .contentShape(Rectangle()).onTapGesture { if !mac.paired { pairing = true } }
                        .sheet(isPresented: $pairing) { MacPairingView().environmentObject(mac) }
                }
                ScrollView {
                    Text(shown).font(Theme.sans(17)).foregroundStyle(mic.isRecording || !last.isEmpty || Demo.on ? Theme.ink : Theme.ink.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
                        .animation(.easeOut(duration: 0.15), value: mic.text)
                }
                .frame(maxHeight: .infinity)
                .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
                Toggle("Carregar Enter depois de colar", isOn: $autoEnter).font(Theme.sans(15)).tint(Theme.green)
                if let e = mic.error { Text(e).font(Theme.sans(12)).foregroundStyle(.red) }
            }
            .padding(.horizontal, 18).padding(.bottom, 12)
            FlowRecorderPanel(phase: Demo.on ? .listening : phase, level: Demo.on ? 0.55 : mic.level, bottomInset: 96, start: begin, cancel: cancel,
                              finish: { Task { await finish() } }, pause: { Task { await ctl.togglePause() } })
        }
        .ignoresSafeArea(edges: .bottom)
        .foregroundStyle(Theme.ink)
        .flowToast($toast, top: 66)
        .onReceive(ctl.$toast) { if let t = $0 { toast = t } }
        .onReceive(NotificationCenter.default.publisher(for: .falaToggle)) { _ in
            if mic.isRecording { Task { await finish() } } else { begin() }
        }
    }

    private var shown: String {
        if Demo.on { return Demo.listening }
        if mic.isRecording { return mic.paused ? "Em pausa. Toca para continuar onde paraste." : (mic.fresh.isEmpty ? "Diz alguma coisa!" : mic.fresh) }
        return last.isEmpty ? "Diz alguma coisa! O texto cola no \(dest), onde estiver o cursor." : last
    }

    private func begin() {
        if !toPC { Task { await ctl.begin() }; return }
        Task {
            let ready = SFSpeechRecognizer.authorizationStatus() == .authorized && AVAudioApplication.shared.recordPermission == .granted
            if !ready, !(await mic.authorize()) { toast = FlowToast(text: "Sem acesso ao microfone", ok: false); return }
            mic.keepAudio = true; mic.start(); if mic.isRecording { pcPhase = .listening }
        }
    }
    private func cancel() { if toPC { Task { _ = await mic.stop(); mic.keepAudio = false; mic.text = ""; pcPhase = .idle } } else { Task { await ctl.cancel() } } }
    private func finish() async { if toPC { await finishPC() } else { await ctl.finish() } }
}

extension DictateView {
    /// Destino PC: Whisper no PC (/stt) se der, senão o texto ao vivo; depois /paste (clipboard + Ctrl+V no PC).
    fileprivate func finishPC() async {
        pcPhase = .processing
        var t = store.process(await mic.stop())
        let audio = mic.lastAudio; mic.keepAudio = false
        if audio.count > 8000, let w = await PCNode.transcribe(audio, prompt: Array(store.dictionary.values).prefix(40).joined(separator: ", ")) {
            let final = store.process(WhisperEngine.scrub(w)); if !final.isEmpty { t = final }
        }
        guard !t.isEmpty else { pcPhase = .idle; return }
        pcLast = t
        UIPasteboard.general.string = t // não se perde se o PC falhar
        let ok = await PCNode.paste(t, enter: autoEnter)
        store.add(t, toMac: ok, seconds: mic.seconds)
        pcPhase = .done(ok ? "Enviado para o PC 🎉" : "Copiado, o PC não respondeu")
        toast = ok ? FlowToast(text: "Colado no PC") : FlowToast(text: "PC sem resposta. Texto copiado", ok: false)
        try? await Task.sleep(for: .seconds(2.2))
        if case .done = pcPhase { pcPhase = .idle }
    }
}

// MARK: - Dicionário / Snippets
struct PairsView: View {
    let title: String
    let keyPath: ReferenceWritableKeyPath<Store, [String: String]>
    @EnvironmentObject var store: Store
    @State private var adding = false
    @State private var from = ""
    @State private var to = ""
    @State private var misspelling = true
    @AppStorage("banner.dict") private var bannerDict = true
    @AppStorage("banner.snip") private var bannerSnip = true
    private var isSnip: Bool { keyPath == \Store.snippets }
    private var banner: Binding<Bool> { isSnip ? $bannerSnip : $bannerDict }

    var body: some View {
        VStack(spacing: 0) {
            FlowHeader { Text(LocalizedStringKey(title)).font(Theme.sans(18, .medium)) } trailing: { Color.clear.frame(width: 44) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if banner.wrappedValue {
                        FlowBanner(title: { Text(isSnip ? "O que não devias ter de reescrever" : "A Fala escreve como tu falas") },
                                   bodyText: isSnip ? Text("Guarda atalhos para o que escreves muitas vezes: ") + Text("emails, links, moradas, bios.").bold() + Text(" Diz o gatilho e aparece tudo.")
                                                    : Text("A Fala aprende as tuas palavras: ") + Text("nomes, marcas, jargão da empresa").bold() + Text(" e termos da área."),
                                   cta: isSnip ? "Novo snippet" : "Adicionar palavra", action: { adding = true },
                                   close: { withAnimation(.spring(duration: 0.35)) { banner.wrappedValue = false } })
                    }
                    let items = store[keyPath: keyPath].sorted(by: { $0.key.localizedLowercase < $1.key.localizedLowercase })
                    Text("\(isSnip ? "Os teus snippets" : "As tuas palavras") (\(items.count))").font(Theme.sans(16)).foregroundStyle(Theme.ink.opacity(0.6)).padding(.leading, 2).padding(.top, 8)
                    if !items.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(items, id: \.key) { k, v in
                                Text(k == v ? k : "\(k) → \(v)").font(Theme.sans(16)).foregroundStyle(Theme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18).contentShape(Rectangle())
                                    .contextMenu { Button("Apagar", systemImage: "trash", role: .destructive) { tick(); withAnimation { store[keyPath: keyPath][k] = nil } } }
                                if k != items.last?.key { Divider() }
                            }
                        }
                        .padding(.horizontal, 18)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 110)
                .animation(.spring(duration: 0.35), value: store[keyPath: keyPath].count)
            }
        }
        .overlay(alignment: .bottomTrailing) { FlowFAB { adding = true }.padding(.trailing, 22).padding(.bottom, 84) }
        .sheet(isPresented: $adding) { addSheet }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isSnip ? "Novo snippet" : "Adicionar ao dicionário").font(Theme.sans(18, .semibold))
                Spacer()
                Button { tick(); adding = false } label: { Image(systemName: "xmark").font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink).frame(width: 32, height: 32).background(Theme.appBG, in: Circle()) }
            }
            if !isSnip { Toggle("Corrigir um erro de escrita", isOn: $misspelling).font(Theme.sans(16)).tint(Theme.green) }
            field(isSnip ? "Gatilho (ex: meu email)" : (misspelling ? "O que a Fala ouve (ex: clode)" : "Palavra"), $from)
            if isSnip || misspelling { field(isSnip ? "Texto a escrever" : "Como deve escrever (ex: Claude)", $to) }
            Button("Guardar") { tick();
                store[keyPath: keyPath][from] = (isSnip || misspelling) ? to : from
                from = ""; to = ""; adding = false
            }
            .buttonStyle(DarkButton(enabled: canSave)).disabled(!canSave)
            Spacer()
        }
        .padding(22).presentationDetents([.medium]).presentationCornerRadius(28)
        .animation(.spring(duration: 0.3), value: misspelling)
    }
    private var canSave: Bool { !from.isEmpty && (!(isSnip || misspelling) || !to.isEmpty) }
    private func field(_ p: String, _ b: Binding<String>) -> some View {
        TextField(p, text: b).font(Theme.sans(16)).padding(.horizontal, 14).frame(height: 50)
            .background(Theme.appBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ScratchView: View {
    @EnvironmentObject var store: Store
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 0) {
            FlowHeader { Text("Notas").font(Theme.sans(18, .medium)) } trailing: {
                if focused { Button("OK") { tick(); focused = false }.font(Theme.sans(16, .semibold)).frame(width: 44, height: 44) } else { Color.clear.frame(width: 44) }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(Date().formatted(.dateTime.day().month(.abbreviated).year())).font(Theme.sans(16)).foregroundStyle(Theme.ink.opacity(0.6)).padding(.leading, 2)
                TextEditor(text: $store.scratchpad).focused($focused).font(Theme.sans(16)).scrollContentBackground(.hidden).padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(alignment: .topLeading) { if store.scratchpad.isEmpty { Text("Apanha uma ideia antes que fuja…").font(Theme.sans(16)).foregroundStyle(Theme.ink.opacity(0.35)).padding(.horizontal, 17).padding(.vertical, 20).allowsHitTesting(false) } }
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, focused ? 8 : 90)
        }
    }
}

// MARK: - Emparelhar com o Mac (código) e endereço remoto (Tailscale)
struct MacPairingView: View {
    @EnvironmentObject var mac: MacSender
    @Environment(\.dismiss) private var dismiss
    @State private var token = MacSender.token
    @State private var host = MacSender.host
    @State private var testing = false
    @State private var result: String?
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { tick(); scanning = true } label: { Label("Ler o QR do Mac ou do PC", systemImage: "qrcode.viewfinder").font(.headline) }
                } footer: { Text("Mac: app Fala, aba iPhone. PC: app Fala para Windows. Aponta e fica ligado para sempre, de qualquer rede.") }
                Section {
                    TextField("Código (ex.: K7QX2M9PAB)", text: $token).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                } header: { Text("Ou escreve o código") }
                .onChange(of: token) { _, t in
                    // Revisão da App Store (sem Mac): o código DEMO mostra a app com dados de exemplo.
                    if t.uppercased() == "DEMO" { UserDefaults.standard.set(true, forKey: "fala.demo"); token = ""; dismiss() }
                }
                Section {
                    TextField("macbook.tail1234.ts.net", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                } header: { Text("Endereço remoto (opcional)") } footer: {
                    Text("Fora de casa já funciona sozinho pela internet (cifrado). Só precisas disto se usares o Tailscale.")
                }
                Section {
                    Button(testing ? "A testar…" : "Testar ligação") { tick(); Task { await test() } }.disabled(testing || token.isEmpty)
                    Button("Testar pela internet (como fora de casa)") { tick();
                        Task {
                            save(); testing = true; defer { testing = false }
                            let t0 = Date()
                            if let n = await mac.pingInternet() { result = "Ligado a \(n) via internet · \(Int(Date().timeIntervalSince(t0) * 1000)) ms ✓" }
                            else { result = mac.lastError ?? "Sem resposta pela internet" }
                        }
                    }.disabled(testing || token.isEmpty)
                    if let result { Text(result).foregroundStyle(result.hasPrefix("Ligado") ? Theme.forest : .red) }
                }
            }
            .navigationTitle("Ligar um computador").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $scanning) {
                QRScanner { url in
                    scanning = false
                    guard let kind = Pairing.apply(url) else { return }
                    if kind == .pc { // QR do PC lido aqui: liga o PC e diz se responde
                        Task { result = await PCNode.isUp() ? "PC ligado ✓ (\(UserDefaults.standard.string(forKey: "fala.pcName") ?? "PC"))" : "PC guardado, mas não respondeu"; await FalaAccount.shared.push() }
                        return
                    }
                    token = MacSender.token; host = MacSender.host
                    Task { await test() }
                }.ignoresSafeArea()
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Feito") { tick(); save(); dismiss() } } }
        }
    }

    private func save() { MacSender.token = token; MacSender.host = host }
    private func test() async {
        save(); testing = true; defer { testing = false }
        // Ping cifrado: prova o código e mostra o caminho e a latência. Não cola nada.
        if let name = await mac.ping(timeout: 10) {
            result = "Ligado a \(name) via \(mac.route ?? "rede") · \(mac.latencyMs ?? 0) ms ✓"
            UserDefaults.standard.set(name, forKey: "fala.macName")
            await mac.flush(); await FalaAccount.shared.push()
        } else { result = mac.lastError ?? "Sem resposta" }
    }
}

import VisionKit
/// Câmara a ler o QR fala://pair do Mac.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let v = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        v.delegate = context.coordinator; try? v.startScanning(); return v
    }
    func updateUIViewController(_ v: DataScannerViewController, context: Context) {}
    func makeCoordinator() -> C { C(found: found) }
    final class C: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void; var done = false
        init(found: @escaping (String) -> Void) { self.found = found }
        func dataScanner(_ d: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(b) in items { if !done, let s = b.payloadStringValue, s.hasPrefix("fala://pair") { done = true; found(s) } }
        }
    }
}
