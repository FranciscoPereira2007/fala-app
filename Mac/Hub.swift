import SwiftUI
import AppKit

// Hub ao estilo do Flow para Mac: sidebar cinza-quente, cartão branco grande, stats em serif.
private let hubBG = Color(red: 0.988, green: 0.988, blue: 0.984)
private let orange = Color(red: 1.0, green: 0.663, blue: 0.275)

enum HubTab: String, CaseIterable, Identifiable {
    case dictation = "Início", iphone = "iPhone", sessions = "Sessões", notetaker = "Notetaker", insights = "Insights", dictionary = "Dicionário",
         snippets = "Snippets", style = "Style", transforms = "Transforms", scratchpad = "Notas", settings = "Definições"
    var id: Self { self }
    var icon: String {
        switch self {
        case .dictation: "mic"; case .iphone: "iphone.radiowaves.left.and.right"; case .sessions: "terminal"; case .insights: "chart.bar"
        case .dictionary: "character.book.closed"; case .snippets: "scissors"; case .style: "textformat"; case .notetaker: "record.circle"; case .transforms: "wand.and.stars"; case .scratchpad: "note.text"; case .settings: "gearshape"
        }
    }
}

struct HubView: View {
    @State private var tab: HubTab
    init(initial: HubTab = .dictation) { _tab = State(initialValue: initial) }
    @AppStorage("hub.sidebarOpen") private var sidebarOpen = true
    @StateObject private var modal = ModalCenter()
    var body: some View {
        VStack(spacing: 0) {
            TopBar(sidebarOpen: $sidebarOpen, openSettings: openSettings).frame(height: 52)
            HStack(spacing: 0) {
                if sidebarOpen { Sidebar(tab: $tab, openSettings: openSettings).frame(width: 218).transition(.move(edge: .leading).combined(with: .opacity)) }
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Flow.bg)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Flow.border))
                    ScrollView {
                        page.padding(.horizontal, 40).padding(.top, 40).padding(.bottom, 40)
                            .frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
                            .id(tab).transition(.opacity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.leading, sidebarOpen ? 0 : 12).padding([.trailing, .bottom], 10)
            }
        }
        .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.25), value: sidebarOpen)
        .animation(Flow.ease, value: tab)
        .font(.figtree(15)).foregroundStyle(Flow.fg).background(Flow.chrome)
        .frame(minWidth: 1140, idealWidth: 1350, minHeight: 750, idealHeight: 850)
        .ignoresSafeArea()
        .environment(\.colorScheme, .light)
        .modifier(ModalHost(center: modal))
        .onAppear { if tab == .settings { tab = .dictation; openSettings() } }
    }
    private func openSettings() { modal.show(SettingsModal(close: modal.close).environmentObject(receiver)) }
    @EnvironmentObject var receiver: MacReceiver

    @ViewBuilder private var page: some View {
        switch tab {
        case .dictation: DictationPage()
        case .iphone: IPhonePage()
        case .sessions: SessionsPage()
        case .insights: InsightsPage()
        case .dictionary: DictionaryPage()
        case .snippets: SnippetsPage()
        case .style: StylePage()
        case .notetaker: NotetakerPage()
        case .transforms: TransformsPage()
        case .scratchpad: ScratchpadPage()
        case .settings: DictationPage()
        }
    }
}

/// Barra de topo do Flow: semáforos a 16/19, botão da sidebar, sino e conta à direita.
struct TopBar: View {
    @Binding var sidebarOpen: Bool
    var openSettings: () -> Void
    @State private var bell = false
    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 72)
            IconButton(system: "sidebar.left", help: "Barra lateral") { sidebarOpen.toggle() }
            Spacer()
            IconButton(system: "bell", help: "Notificações") { bell.toggle() }
                .popover(isPresented: $bell, arrowEdge: .bottom) { NotificationsPanel() }
            IconButton(system: "person.crop.circle", help: "Conta", action: openSettings)
        }
        .padding(.horizontal, 14)
    }
}

struct IconButton: View {
    let system: String, help: String, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 15, weight: .regular)).foregroundStyle(Flow.fg)
                .frame(width: 30, height: 30)
                .background(hover ? Flow.bg2 : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).help(help)
        .onHover { h in withAnimation(Flow.ease) { hover = h } }
    }
}

struct Sidebar: View {
    @Binding var tab: HubTab
    var openSettings: () -> Void
    @State private var help = false
    @EnvironmentObject var receiver: MacReceiver
    @AppStorage("hub.mobileCard") private var showCard = true
    @Namespace private var sel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: 2.5) {
                    ForEach([14.0, 20, 11, 17], id: \.self) { h in RoundedRectangle(cornerRadius: 1).frame(width: 2.5, height: h) }
                }.frame(height: 20, alignment: .bottom)
                Text("Fala").font(.figtree(23, weight: 650)).kerning(-0.4)
            }
            .padding(.leading, 12).padding(.top, 14).padding(.bottom, 26)
            ForEach(HubTab.allCases.filter { $0 != .settings && $0 != .snippets }) { t in row(t) } // ponytail: Snippets escondido a pedido do Fran
            Spacer(minLength: 12)
            if showCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Fala no iPhone 📱").font(.figtree(15, weight: 600))
                        Spacer()
                        Button { withAnimation(Flow.ease) { showCard = false } } label: { Image(systemName: "minus").foregroundStyle(Flow.fg3) }.buttonStyle(.plain)
                    }
                    Text("Mac quente? Fala no iPhone e o texto aparece aqui.").font(.figtree(14)).foregroundStyle(Flow.fg3)
                    Button("Abrir") { tab = .iphone }.buttonStyle(.plain).font(.figtree(14, weight: 600))
                        .padding(.horizontal, 16).padding(.vertical, 8).background(Flow.bg2, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 6)
                }
                .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Flow.border))
                .transition(.opacity)
            }
            Divider().overlay(Flow.border).padding(.vertical, 10)
            FooterRow(icon: "gearshape", title: "Definições", action: openSettings)
            FooterRow(icon: "questionmark.circle", title: "Ajuda") { help.toggle() }
                .popover(isPresented: $help, arrowEdge: .trailing) { HelpMenu { help = false; openSettings() } }
            Spacer().frame(height: 10)
        }
        .padding(.horizontal, 12)
    }

    private func row(_ t: HubTab) -> some View {
        SidebarRow(t: t, selected: tab == t, ns: sel, badge: t == .iphone ? (receiver.status.hasPrefix("À escuta") ? "Ligado" : "Novo!") : (t == .notetaker ? "Novo!" : nil)) {
            withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.28)) { tab = t }
        }
    }
}

struct SidebarRow: View {
    let t: HubTab, selected: Bool, ns: Namespace.ID, badge: String?, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: t.icon).font(.system(size: 16, weight: .regular)).frame(width: 20)
                Text(t.rawValue).font(.figtree(15, weight: 500)).lineLimit(1).fixedSize()
                Spacer()
                if let badge {
                    Text(badge).font(.figtree(12, weight: 550)).foregroundStyle(Flow.fg).lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(hex: 0xf9b45c), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background {
                if selected { RoundedRectangle(cornerRadius: 8).fill(Flow.bg2).matchedGeometryEffect(id: "sel", in: ns) }
                else if hover { RoundedRectangle(cornerRadius: 8).fill(Flow.bg2.opacity(0.5)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.bottom, 4)
        .onHover { h in withAnimation(Flow.ease) { hover = h } }
    }
}

struct FooterRow: View {
    let icon: String, title: String, action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 15)).frame(width: 20); Text(LocalizedStringKey(title)).font(.figtree(15, weight: 500)) }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .background(hover ? Flow.bg2.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { h in withAnimation(Flow.ease) { hover = h } }
    }
}

// MARK: Ditado (home): banner, histórico por dia, stats.
struct DictationPage: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(Me.firstName.isEmpty ? "Bem-vindo de volta" : "Bem-vindo de volta, \(Me.firstName)").font(.figtree(28, weight: 550))
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 40) { banner; HistoryList() }
                StatsCard().frame(width: 250)
            }
        }
    }
    private var banner: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("Segura ") + Text("fn").italic() + Text(" e fala")).font(.garamond(36)).kerning(-0.6)
            Text("Em qualquer app. Larga, e o texto aparece onde está o cursor.").font(.figtree(16))
        }
        .foregroundStyle(Color(hex: 0xfcfcfb)).padding(.horizontal, 32).frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
        .background {
            ZStack {
                Color.black
                LinearGradient(colors: [.clear, Color(hex: 0x84663e).opacity(0.85), Color(hex: 0x3c2947)], startPoint: .leading, endPoint: .trailing)
                    .blur(radius: 30).opacity(0.9)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StatsCard: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(store.totalWords.formatted(.number.notation(.compactName)), "palavras no total")
            if store.wpm > 0 { row("\(store.wpm)", "ppm") } else { HStack(alignment: .firstTextBaseline, spacing: 8) { Text("ppm").font(.figtree(16)); Text("ainda sem dados").font(.figtree(14)).foregroundStyle(Flow.fg3) } }
            row("\(store.streak)", store.streak == 1 ? "dia seguido" : "dias seguidos")
            let goal = PillController.dailyGoal, today = store.wordsToday, f = min(1, Double(today) / Double(max(goal, 1)))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Meta de hoje").font(.figtree(13, weight: 600))
                    Spacer()
                    Text(f >= 1 ? "Feita ✓" : "\(today)/\(goal)").font(.figtree(13)).foregroundStyle(f >= 1 ? Color(hex: 0x2f8f55) : Flow.fg3).contentTransition(.numericText())
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Flow.bg2)
                        Capsule().fill(f >= 1 ? Color(hex: 0x4fbf78) : Flow.fg).frame(width: max(6, g.size.width * f))
                    }
                }.frame(height: 6).animation(.spring(duration: 0.6, bounce: 0.25), value: f)
            }.padding(.top, 6)
        }
        .padding(.horizontal, 24).padding(.vertical, 28).frame(maxWidth: .infinity, alignment: .leading)
        .background(Flow.bg3, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Flow.border))
    }
    func row(_ v: String, _ l: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(v).font(.garamond(30)).contentTransition(.numericText())
            Text(l).font(.figtree(16))
        }
    }
}

struct HistoryList: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var searching = false
    var body: some View {
        let shown = store.entries.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        let days = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: $0.date) }.sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 14) {
            if days.isEmpty {
                header(Date())
                Text("Ainda não ditaste nada. Segura fn e diz a tua primeira frase.").font(.figtree(15)).foregroundStyle(Flow.fg3)
            }
            ForEach(Array(days.enumerated()), id: \.element.key) { idx, pair in
                header(pair.key, search: idx == 0)
                VStack(spacing: 0) {
                    ForEach(pair.value) { e in
                        HistoryRow(e: e)
                        if e.id != pair.value.last?.id { Rectangle().fill(Flow.border).frame(height: 1) }
                    }
                }
                .background(Flow.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Flow.border))
                .padding(.bottom, 18)
            }
        }
    }
    private func header(_ d: Date, search: Bool = true) -> some View {
        HStack {
            Text(d.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "pt_PT"))).uppercased())
                .font(.figtree(13, weight: 600)).kerning(1.3).foregroundStyle(Flow.fg3)
            Spacer()
            if search {
                if searching {
                    TextField("Procurar", text: $query).textFieldStyle(.plain).font(.figtree(14)).frame(width: 180)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
                Button { withAnimation(Flow.ease) { searching.toggle(); if !searching { query = "" } } } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Flow.fg3)
                }.buttonStyle(.plain)
            }
        }
    }
}

struct HistoryRow: View {
    let e: Entry
    @State private var hover = false
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 4) {
                Text(e.date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "pt_PT")))).font(.figtree(14)).foregroundStyle(Flow.fg3)
                if e.toMac { Image(systemName: "iphone").font(.system(size: 11)).foregroundStyle(Flow.fg3) }
            }.frame(width: 120, alignment: .leading)
            Text(e.text).font(.figtree(15)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.text, forType: .string) } label: {
                    Image(systemName: "doc.on.doc").frame(width: 28, height: 28)
                }.buttonStyle(.plain).help("Copiar")
            }
            .foregroundStyle(Flow.fg3).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(hover ? Flow.bg3 : .clear)
        .onHover { h in withAnimation(Flow.ease) { hover = h } }
        .contextMenu { Button("Copiar") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.text, forType: .string) } }
    }
}

// MARK: iPhone (a aba nova): estado da ligação, código, recebidos e um momento quando o texto chega.
struct IPhonePage: View {
    @EnvironmentObject var receiver: MacReceiver
    @EnvironmentObject var store: Store
    @State private var arrived = false
    @State private var pulse = false
    private var listening: Bool { receiver.status.hasPrefix("À escuta") }
    private var got: [Entry] { Array(store.entries.filter(\.toMac).prefix(30)) }
    private var todayWords: Int {
        store.entries.filter { $0.toMac && Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.text.split(separator: " ").count }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline) {
                (Text("Fala no iPhone, ") + Text("escreve aqui").italic()).font(.garamond(40)).kerning(-0.6)
                Spacer()
                if todayWords > 0 {
                    Text("\(todayWords) palavras do iPhone hoje").font(.figtree(13, weight: 600))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Flow.lilac, in: Capsule()).contentTransition(.numericText())
                }
            }
            Text("Mac quente ou longe do teclado? Abre a Fala no iPhone, aba Mac, toca e fala. O texto cola onde estiver o cursor, aqui no Mac.")
                .font(.figtree(15)).foregroundStyle(Flow.fg3).frame(maxWidth: 560, alignment: .leading)
            HStack(alignment: .top, spacing: 14) {
                StatusTile(icon: "wifi", title: "Rede local", value: listening ? "À escuta" : receiver.status, ok: listening, pulse: pulse && listening)
                StatusTile(icon: "globe", title: "Fora de casa", value: remoteValue, ok: receiver.remote?.running == true, pulse: false)
                StatusTile(icon: "hand.raised", title: "Colar sozinho", value: AXIsProcessTrusted() ? "Ativo" : "Falta Acessibilidade", ok: AXIsProcessTrusted(), pulse: false) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
            if let at = receiver.lastContact {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Label("Último contacto do iPhone \(at.formatted(.relative(presentation: .named))) via \(receiver.lastRoute ?? "rede")" + (receiver.queuedDelivered > 0 ? " · \(receiver.queuedDelivered) da fila no histórico" : ""), systemImage: "dot.radiowaves.left.and.right")
                        .font(.figtree(13)).foregroundStyle(Flow.fg3)
                }
            }
            RemoteCard().environmentObject(receiver)
            VStack(alignment: .leading, spacing: 0) {
                Text("Recebido do iPhone").font(.figtree(13, weight: 600)).foregroundStyle(Flow.fg3).padding(.bottom, 12)
                if got.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 28, weight: .light)).foregroundStyle(Flow.fg3)
                            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: listening)
                        Text("À espera da primeira frase").font(.figtree(15, weight: 600))
                        Text("Diz algo no iPhone e vês aqui a frase a chegar.").font(.figtree(13)).foregroundStyle(Flow.fg3)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    .background(Flow.bg3, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(got.enumerated()), id: \.element.id) { i, e in
                            ReceivedRow(e: e, fresh: i == 0 && arrived)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                            if i < got.count - 1 { RowDivider() }
                        }
                    }
                    .background(Flow.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Flow.border))
                    .animation(.spring(duration: 0.45, bounce: 0.3), value: got.first?.id)
                }
            }
        }
        .onChange(of: receiver.lastReceived) {
            arrived = true; pulse = true
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(.easeOut(duration: 0.6)) { arrived = false; pulse = false } }
        }
    }
    private var remoteValue: String {
        guard let r = receiver.remote else { return "A verificar…" }
        return r.running ? "Tailscale ligado" : r.note
    }
}

struct StatusTile: View {
    let icon: String, title: String, value: String, ok: Bool, pulse: Bool
    var fix: (() -> Void)? = nil
    @State private var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Spacer()
                Circle().fill(ok ? Color(hex: 0x4fbf78) : Flow.orange).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(hex: 0x4fbf78).opacity(pulse ? 0 : 0.5), lineWidth: 2).scaleEffect(pulse ? 2.6 : 1))
                    .animation(.easeOut(duration: 0.9), value: pulse)
            }
            Text(LocalizedStringKey(title)).font(.figtree(13)).foregroundStyle(Flow.fg3)
            Text(value).font(.figtree(15, weight: 600)).lineLimit(1)
            if !ok, let fix { Button("Resolver", action: fix).buttonStyle(FlowButton(kind: .beige, small: true)) }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(hover ? Flow.bg3 : Flow.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Flow.border))
        .onHover { h in withAnimation(Flow.ease) { hover = h } }
    }
}

struct ReceivedRow: View {
    let e: Entry, fresh: Bool
    @State private var hover = false
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(e.date.formatted(date: .omitted, time: .shortened)).font(.figtree(13)).foregroundStyle(Flow.fg3).frame(width: 56, alignment: .leading)
            Text(e.text).font(.figtree(15)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if fresh { Label("Colado", systemImage: "checkmark").font(.figtree(12, weight: 600)).foregroundStyle(Color(hex: 0x2f8f55)).transition(.scale.combined(with: .opacity)) }
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.text, forType: .string); copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false } } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 12)).contentTransition(.symbolEffect(.replace))
            }.buttonStyle(.plain).foregroundStyle(Flow.fg3).opacity(hover || copied ? 1 : 0).help("Copiar")
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(fresh ? Flow.lilac.opacity(0.55) : (hover ? Flow.bg3 : .clear))
        .onHover { h in withAnimation(Flow.ease) { hover = h } }
    }
}

/// Código de emparelhamento + endereço Tailscale para usar o iPhone fora de casa.
struct RemoteCard: View {
    @EnvironmentObject var receiver: MacReceiver
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Ligar o iPhone").font(.figtree(16, weight: 600))
                Spacer()
                Button("Atualizar") { receiver.refreshRemote() }.buttonStyle(FlowButton(kind: .beige, small: true))
                Button("Novo código") { receiver.regenerateToken() }.buttonStyle(FlowButton(kind: .beige, small: true))
            }
            Text("No iPhone: menu, Ligar ao Mac, cola o código. Na mesma rede, o Mac aparece sozinho.").font(.figtree(13)).foregroundStyle(Flow.fg3)
            HStack(alignment: .top, spacing: 18) {
                if let qr = PairQR.image(receiver.pairURL) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                        .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Aponta a câmara do iPhone ao QR e toca em Abrir na Fala. Fica ligado para sempre.").font(.figtree(13)).foregroundStyle(Flow.fg3)
                    CopyRow(k: "Código", v: receiver.token, big: true)
                }
            }
            if let r = receiver.remote, r.running, let addr = r.dns ?? r.ip {
                CopyRow(k: "Fora de casa", v: addr)
                if let ip = r.ip, r.dns != nil { CopyRow(k: "ou", v: ip) }
                Text("Porta \(String(receiver.port)). Funciona em qualquer rede com o Tailscale ligado nos dois.").font(.figtree(12)).foregroundStyle(Flow.fg3)
            } else {
                Text("Para usar fora de casa: instala o Tailscale (grátis) neste Mac e no iPhone, com a mesma conta. O endereço aparece aqui.")
                    .font(.figtree(13)).foregroundStyle(Flow.fg3).frame(maxWidth: 560, alignment: .leading)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(Flow.bg3, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Flow.border))
    }
}

struct CopyRow: View {
    let k: String, v: String
    var big = false
    @State private var copied = false
    var body: some View {
        HStack(spacing: 12) {
            Text(k).font(.figtree(13)).foregroundStyle(Flow.fg3).frame(width: 96, alignment: .leading)
            Text(v).font(.system(size: big ? 20 : 14, weight: .semibold, design: .monospaced)).kerning(big ? 2 : 0).textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(v, forType: .string)
                withAnimation(FlowEase.pop) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
            } label: {
                Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc").font(.figtree(12, weight: 600))
            }.buttonStyle(FlowButton(kind: copied ? .black : .beige, small: true))
        }
    }
}

import CoreImage.CIFilterBuiltins
/// QR com fala://pair?t=CÓDIGO&h=ENDEREÇO. A câmara do iPhone abre a Fala e guarda tudo.
enum PairQR {
    static func image(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator(); f.message = Data(text.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: .init(width: out.extent.width, height: out.extent.height))
    }
}
