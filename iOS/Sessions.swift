import SwiftUI
import AVFoundation
import UserNotifications
import Speech
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Modelo (iPhone)

/// Fala com o Mac pelo canal cifrado: lista de sessões, mensagens, enviar prompt e eventos.
@MainActor final class JarvisModel: ObservableObject {
    @Published var sessions: [Jarvis.Session] = []
    @Published var loading = false
    @Published var error: String?
    @Published var messages: [String: [Jarvis.Message]] = [:]
    /// Enviadas com a sessão a trabalhar: o agente só as escreve no histórico quando pega nelas. Até lá, "Na fila".
    @Published var queued: [String: [String]] = [:]
    private func settle(_ id: String) {
        let mine = (messages[id] ?? []).filter { $0.role == "user" }.suffix(10).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        queued[id]?.removeAll { q in mine.contains { $0.hasPrefix(String(q.prefix(40))) } }
    }
    private var lastEvent: Int? = UserDefaults.standard.object(forKey: "jarvis.lastEvent") as? Int
    private var timer: Timer?
    weak var mac: MacSender?

    /// Nomes dados pelo Fran (só no iPhone). Vazio = nome original.
    @Published var alias: [String: String] = UserDefaults.standard.dictionary(forKey: "jarvis.alias") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(alias, forKey: "jarvis.alias") }
    }
    @Published var archived: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "jarvis.archived") ?? []) {
        didSet { UserDefaults.standard.set(Array(archived), forKey: "jarvis.archived") }
    }
    @Published var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "jarvis.pinned") ?? []) {
        didSet { UserDefaults.standard.set(Array(pinned), forKey: "jarvis.pinned") }
    }
    func title(_ s: Jarvis.Session) -> String { alias[s.id].flatMap { $0.isEmpty ? nil : $0 } ?? s.name }
    /// Ativa = a trabalhar, à tua espera, ou mexeu nos últimos 30 min.
    /// Ativa = processo vivo num terminal (o Mac só devolve pid de processos vivos), a trabalhar ou não; sem pid (Codex) conta a hora.
    static func isActive(_ s: Jarvis.Session) -> Bool { s.pid != nil || s.busy || s.needsYou || s.updatedAt > Date().addingTimeInterval(-1800) }

    @Published var commands: [String] = []
    var mediaCache: [String: Data] = [:]
    @Published var commandsError: String?
    @Published var chatOpen = false   // esconde a barra de abas dentro de uma conversa
    private var loadingCommands = false
    func loadCommands() async {
        guard commands.isEmpty, !loadingCommands else { return }
        loadingCommands = true; defer { loadingCommands = false }
        if let r = await mac?.jarvis(.init(op: "commands"), timeout: 20), let c = r.commands, !c.isEmpty { commands = c; commandsError = nil }
        else { commandsError = mac?.lastError ?? "O Mac não mandou a lista" }
    }

    /// Muda o nome também no Mac: Claude Code recebe "/rename"; Codex fica só com o nome local.
    func rename(_ s: Jarvis.Session, to name: String) async {
        alias[s.id] = name
        if s.kind == .claude, !name.isEmpty { _ = await send(s.id, "/rename " + name) }
    }

    func refresh() async {
        if Demo.on { sessions = Demo.sessions; return }
        if !MacSender.paired, !PCNode.code.isEmpty { // só PC (Windows): fala direto com ele
            loading = sessions.isEmpty; defer { loading = false }
            guard let (s, _, d) = await PCNode.request("GET", "/sessions", timeout: 10), s == 200,
                  let list = try? Jarvis.decoder.decode([Jarvis.Session].self, from: d) else { error = "O PC não respondeu"; return }
            error = nil
            sessions = list.map { var x = $0; x.id = "pc:" + x.id; x.cwd = x.cwd.replacingOccurrences(of: "\\", with: "/"); return x }
            return
        }
        guard let mac else { return }
        loading = sessions.isEmpty
        defer { loading = false }
        guard let r = await mac.jarvis(.init(op: "list")) else { error = mac.lastError ?? "O Mac não respondeu"; return }
        error = nil
        sessions = r.sessions ?? []
        if lastEvent == nil, let l = r.lastEvent { setLast(l) } // 1.ª vez: não notifica o passado
    }

    func load(_ id: String) async {
        if Demo.on { messages[id] = Demo.messages; return }
        if !MacSender.paired, id.hasPrefix("pc:") {
            let raw = String(id.dropFirst(3)).addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-"))) ?? ""
            if let (s, _, d) = await PCNode.request("GET", "/tail?id=\(raw)&limit=60", timeout: 10), s == 200,
               let m = try? Jarvis.decoder.decode([Jarvis.Message].self, from: d), !m.isEmpty, m != messages[id] { messages[id] = m; settle(id) }
            return
        }
        guard let r = await mac?.jarvis(.init(op: "tail", id: id, limit: 60)) else { return }
        if let m = r.messages, !m.isEmpty || messages[id] == nil, m != messages[id] { messages[id] = m } // falha ou vazio de passagem: fica o que já se via
        settle(id)
    }

    func send(_ id: String, _ text: String, fileName: String? = nil, file: Data? = nil) async -> String? {
        guard AIConsent.given else { return "Aceita primeiro o aviso da aba Sessões." }
        if !MacSender.paired, id.hasPrefix("pc:") {
            let body = try? JSONSerialization.data(withJSONObject: ["id": String(id.dropFirst(3)), "text": text])
            guard let (_, _, d) = await PCNode.request("POST", "/send", body: body, timeout: 35),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "O PC não respondeu" }
            if j["ok"] as? Bool == true { queued[id, default: []].append(text.trimmingCharacters(in: .whitespacesAndNewlines)); try? await Task.sleep(for: .milliseconds(600)); await load(id); return nil }
            return j["error"] as? String ?? "Falhou no PC"
        }
        guard let r = await mac?.jarvis(.init(op: "send", id: id, text: text, fileName: fileName, file: file), timeout: file == nil ? 20 : 60) else { return mac?.lastError ?? "O Mac não respondeu" }
        if r.ok { queued[id, default: []].append(text.trimmingCharacters(in: .whitespacesAndNewlines)); try? await Task.sleep(for: .milliseconds(600)); await load(id) }
        return r.ok ? nil : (r.error ?? "Falhou")
    }

    /// Chamada sem Mac: manda o pedido à sessão e espera pela resposta (mensagem nova do agente, e 6 s sem mudanças).
    func ask(_ id: String, _ text: String) async -> String {
        let sent = Date()
        if let e = await send(id, text) { return e }
        var last: Jarvis.Message?, still = Date()
        for _ in 0..<300 {
            try? await Task.sleep(for: .seconds(2))
            await load(id)
            let reply = messages[id]?.last { $0.role == "agent" && $0.at > sent.addingTimeInterval(-2) }
            if reply?.id != last?.id || reply?.text != last?.text { last = reply; still = Date() }
            if let last, Date().timeIntervalSince(still) > 6 { return last.text }
        }
        return last?.text ?? "A sessão ainda está a trabalhar."
    }

    /// Enquanto a app está aberta: de 6 em 6 s pergunta ao Mac se alguma sessão terminou ou precisa de ti.
    func startWatching() {
        guard timer == nil else { return }
        if Demo.on { return } // capturas sem o pedido do sistema por cima
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in Task { @MainActor in await self?.pollEvents() } }
    }

    func pollEvents() async {
        guard let mac, mac.jarvisReady, let since = lastEvent else { return }
        guard let r = await mac.jarvis(.init(op: "events", since: since), timeout: 5) else { return }
        for e in r.events ?? [] { notify(e) }
        if let l = r.lastEvent { setLast(l) }
        if !(r.events ?? []).isEmpty { await refresh() }
    }

    private func setLast(_ l: Int) { lastEvent = l; UserDefaults.standard.set(l, forKey: "jarvis.lastEvent") }

    /// /dopamina: o que os agentes já fizeram hoje (contagem verdadeira dos avisos "terminou").
    @Published var doneToday: Int = {
        let d = UserDefaults.standard
        return d.string(forKey: "jarvis.doneDay") == Date().formatted(.iso8601.year().month().day()) ? d.integer(forKey: "jarvis.doneCount") : 0
    }()
    private func countDone() {
        let d = UserDefaults.standard, today = Date().formatted(.iso8601.year().month().day())
        if d.string(forKey: "jarvis.doneDay") != today { d.set(today, forKey: "jarvis.doneDay"); doneToday = 0 }
        doneToday += 1; d.set(doneToday, forKey: "jarvis.doneCount")
    }

    private func notify(_ e: Jarvis.Event) {
        if e.kind == .finished { countDone() }
        let c = UNMutableNotificationContent()
        c.title = e.kind == .finished ? "\(e.sessionName) terminou" : "\(e.sessionName) precisa de ti"
        c.body = e.summary
        c.sound = .default
        c.interruptionLevel = e.kind == .needsYou ? .timeSensitive : .active
        c.userInfo = ["session": e.sessionID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "jarvis.\(e.id)", content: c, trigger: nil))
    }
}

// MARK: - Aba Sessões

/// 5.1.2(i): antes de mandar texto ou o ecrã para IA de terceiros, a pessoa aceita (uma vez).
enum AIConsent {
    static var given: Bool { UserDefaults.standard.bool(forKey: "fala.aiConsent") || Demo.on }
    static let text = "O que pedes ao Jarvis e às sessões vai do teu computador para a conta de IA que lá ligaste (Claude, da Anthropic, ou ChatGPT, da OpenAI), que pode ver o texto e capturas do ecrã. A Fala não guarda nem vende nada."
}

struct SessionsView: View {
    @AppStorage("fala.aiConsent") private var consent = false
    @State private var askConsent = false
    @EnvironmentObject var mac: MacSender
    @EnvironmentObject var jarvis: JarvisModel
    @State private var open: Jarvis.Session?
    @State private var dotChat = false
    @State private var dotCall = false
    @State private var pcCall: Jarvis.Session?   // chamada a uma sessão do PC sem Mac (voz no iPhone)
    @ObservedObject private var dot = DotModel.shared
    @State private var renaming: Jarvis.Session?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Color.clear.frame(height: 0)
                    .onAppear { if !AIConsent.given { askConsent = true } }
                    .alert("As tuas IAs", isPresented: $askConsent) {
                        Button("Aceito") { consent = true }
                        Button("Agora não", role: .cancel) {}
                    } message: { Text(AIConsent.text) }
                FlowHeader { Text("Sessões").font(Theme.sans(18, .medium)) } trailing: {
                    Button { tick(); Task { await jarvis.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").font(Theme.sans(16, .semibold)).frame(width: 44, height: 44)
                    }.buttonStyle(.plain)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        (Text("Os teus agentes, ").font(Theme.garamond(28)) + Text("no bolso").font(Theme.garamond(28, italic: true)).foregroundColor(Theme.orange))
                            .padding(.top, 8)
                        if jarvis.doneToday > 0 {
                            Label("Hoje: \(jarvis.doneToday) \(jarvis.doneToday == 1 ? "tarefa terminada" : "tarefas terminadas")", systemImage: "checkmark.seal.fill")
                                .font(Theme.sans(14, .semibold)).foregroundStyle(Theme.forest)
                                .contentTransition(.numericText()).animation(.spring(duration: 0.4), value: jarvis.doneToday)
                        }
                        if let e = jarvis.error, jarvis.sessions.isEmpty {
                            Label(e, systemImage: "wifi.exclamationmark").font(Theme.sans(14)).foregroundStyle(Theme.muted)
                        }
                        if jarvis.loading { ProgressView().frame(maxWidth: .infinity).padding(30) }
                        if !jarvis.loading, jarvis.sessions.isEmpty, jarvis.error == nil {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Nenhuma sessão a correr no Mac.").font(Theme.sans(16, .semibold))
                                Text("Abre o Claude Code no iTerm ou uma conversa no Codex e ela aparece aqui sozinha.").font(Theme.sans(14)).foregroundStyle(Theme.muted)
                                Button { tick(); Task { await jarvis.refresh() } } label: { Label("Procurar outra vez", systemImage: "arrow.clockwise") }
                                    .font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink)
                            }
                                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        // As conversas do teu Jarvis (pasta Fala/Jarvis) vivem no cartão dele, não na lista.
                        let shown = jarvis.sessions.filter { !jarvis.archived.contains($0.id) && !$0.cwd.hasSuffix("Fala/Jarvis") }
                        let pins = shown.filter { jarvis.pinned.contains($0.id) }, rest = shown.filter { !jarvis.pinned.contains($0.id) }
                        // Primeiro as que precisam de ti (aprovação), depois as que trabalham, depois as livres.
                        let active = rest.filter(JarvisModel.isActive).sorted { ($0.needsYou ? 0 : $0.busy ? 1 : 2) < ($1.needsYou ? 0 : $1.busy ? 1 : 2) }, old = rest.filter { !JarvisModel.isActive($0) }
                        group("Afixadas", pins)
                        group("Ativas agora", active)
                        group("Antigas", old)
                    }
                    .padding(.horizontal, 18).padding(.bottom, 110)
                    .animation(.spring(duration: 0.35), value: jarvis.sessions.map(\.status))
                }
                .refreshable { await jarvis.refresh() }
            }
            .background(Theme.appBG.ignoresSafeArea())
            .navigationDestination(item: $open) { s in SessionChatView(session: s, call: {
                if !MacSender.paired, s.id.hasPrefix("pc:") { pcCall = s } else { CallCenter.shared.call(s, mac: mac) }
            }) }
            .fullScreenCover(item: $pcCall) { s in DotCallView(title: s.name, ask: { await jarvis.ask(s.id, $0) }) }
            .navigationDestination(isPresented: $dotChat) { DotChatView(call: { dotCall = true }) }
            .fullScreenCover(isPresented: $dotCall) { DotCallView() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            jarvis.mac = mac; await jarvis.refresh(); jarvis.startWatching()
            if Demo.open == "chat" { open = jarvis.sessions.first } // capturas
            if Demo.open == "dotchat" { dotChat = true }
            if Demo.open == "dotcall" { dotCall = true }
        }
        .alert("Renomear sessão", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Guardar") { tick(); if let r = renaming { let n = newName.trimmingCharacters(in: .whitespaces); Task { await jarvis.rename(r, to: n) } } }
            Button("Cancelar", role: .cancel) {}
        }
    }

    @ViewBuilder private func group(_ title: String, _ list: [Jarvis.Session]) -> some View {
        if !list.isEmpty {
            Text(title.uppercased() + " · \(list.count)").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.muted).padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(list) { s in
                    Button { tick(); open = s } label: { row(s) }.buttonStyle(.plain)
                        .contextMenu {
                            let pin = jarvis.pinned.contains(s.id)
                            Button { tick(); if pin { jarvis.pinned.remove(s.id) } else { jarvis.pinned.insert(s.id) } } label: { Label(pin ? "Desafixar" : "Afixar", systemImage: pin ? "pin.slash" : "pin") }
                            Button { tick(); newName = jarvis.title(s); renaming = s } label: { Label("Mudar o nome", systemImage: "pencil") }
                            Button { tick(); UIPasteboard.general.string = s.id } label: { Label("Copiar ID", systemImage: "doc.on.doc") }
                            Divider()
                            Button(role: .destructive) { tick(); jarvis.archived.insert(s.id) } label: { Label("Arquivar", systemImage: "archivebox") }
                        } preview: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(jarvis.title(s)).font(Theme.sans(17, .semibold))
                                Text(s.folder + " · " + (s.needsYou ? "precisa de ti" : s.busy ? "a trabalhar" : "livre")).font(Theme.sans(13)).foregroundStyle(Theme.muted)
                                Text(s.lastReply ?? "Sem mensagens ainda.").font(Theme.sans(15)).lineLimit(8)
                            }.padding(18).frame(width: 320, alignment: .leading).background(Theme.appBG)
                        }
                    if s.id != list.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 16)
            .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .opacity(title == "Antigas" ? 0.75 : 1)
        }
    }

    private func row(_ s: Jarvis.Session) -> some View {
        // Limpo: o pet (diz logo se trabalha ou espera), o nome e numa frase o que está a fazer.
        HStack(alignment: .center, spacing: 12) {
            SessionPet(id: s.id, busy: s.busy, active: JarvisModel.isActive(s), needsYou: s.needsYou)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(jarvis.title(s)).font(Theme.sans(16, .semibold)).lineLimit(1)
                    DeviceTag(id: s.id)
                }
                if s.needsYou { Text("Precisa de ti").font(Theme.sans(14, .medium)).foregroundStyle(Theme.orange) }
                else if s.busy {
                    HStack(spacing: 2) {
                        Text(s.doing ?? s.lastReply ?? "A trabalhar").lineLimit(1)
                        WorkingDots()
                    }.font(Theme.sans(14)).foregroundStyle(Theme.green)
                    .contentTransition(.opacity).animation(.easeInOut(duration: 0.3), value: s.doing)
                } else if s.shell { Label("Comando em fundo a correr", systemImage: "terminal").font(Theme.sans(13)).foregroundStyle(Theme.muted) }
                else if let r = s.lastReply, !r.isEmpty { Text(r).font(Theme.sans(14)).foregroundStyle(Theme.ink.opacity(0.55)).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14).contentShape(Rectangle())
    }
}

// MARK: - Conversa com uma sessão

struct SessionChatView: View {
    let session: Jarvis.Session
    var call: () -> Void
    @EnvironmentObject var jarvis: JarvisModel
    @EnvironmentObject var mac: MacSender
    @EnvironmentObject var mic: Transcriber
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var sending = false
    @State private var dictating = false
    @State private var toast: FlowToast?
    @State private var confirm = false
    @State private var pickPhoto = false
    @State private var pickFile = false
    @State private var camera = false
    @State private var photo: PhotosPickerItem?
    @State private var attach: Data?
    @State private var attachName: String?

    private var live: Jarvis.Session { jarvis.sessions.first { $0.id == session.id } ?? session }

    var body: some View {
        VStack(spacing: 0) {
            FlowHeader(menu: { dismiss() }, menuIcon: "chevron.left") {
                HStack(spacing: 4) {
                    SessionPet(id: session.id, busy: live.busy, active: true, needsYou: live.needsYou).scaleEffect(0.8).frame(width: 38, height: 40)
                    Text(jarvis.title(live)).font(Theme.sans(17, .semibold)).lineLimit(1)
                    DeviceTag(id: session.id)
                }.accessibilityElement(children: .combine)
            } trailing: {
                // ponytail: chamadas cortadas (decisão do Fran, 28 out): o modo voz já faz o mesmo.
                Color.clear.frame(width: 44, height: 44)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) { // ponytail: VStack, 60 mensagens; o Lazy ficava em branco ao mudar a altura da caixa
                        ForEach(jarvis.messages[session.id] ?? []) { m in bubble(m).id(m.id) }
                        ForEach(Array((jarvis.queued[session.id] ?? []).enumerated()), id: \.offset) { _, t in
                            VStack(alignment: .trailing, spacing: 4) {
                                bubble(.init(id: "q" + t, role: "user", text: t, at: Date())).opacity(0.75)
                                Label(live.busy ? "Na fila: entra quando acabar o que está a fazer" : "Enviada", systemImage: "clock")
                                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                            }.frame(maxWidth: .infinity, alignment: .trailing).transition(.opacity)
                        }
                        if live.busy { WorkingRow().id("working") }
                        else if live.shell { Label("Parado, com um comando em fundo a correr", systemImage: "terminal").font(Theme.sans(13)).foregroundStyle(Theme.muted).padding(.leading, 4) }
                    }.padding(.horizontal, 16).padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively) // ao subir para ler, o teclado desce e as mensagens ganham espaço
                .onChange(of: jarvis.messages[session.id]?.last?.id) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            composer
        }
        .ignoresSafeArea(.container, edges: .bottom) // a caixa desce até junto da barra do iPhone
        .background(Theme.appBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if camera {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { withAnimation(.spring(duration: 0.35)) { camera = false } }
                    LiveCameraCard(close: { withAnimation(.spring(duration: 0.35)) { camera = false } }) { img in
                        withAnimation(.spring(duration: 0.35)) { attach = Self.shrink(img).jpegData(compressionQuality: 0.75); attachName = "foto.jpg"; camera = false }
                    }
                    .transition(.scale(scale: 0.2, anchor: .bottomLeading).combined(with: .opacity)) // cresce a partir do "+"
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .flowToast($toast, top: 66)
        .task { await jarvis.loadCommands() }
        .onChange(of: slashWord != nil) { _, on in if on, jarvis.commands.isEmpty { Task { await jarvis.loadCommands() } } }
        .background(PagerLock())
        .onAppear { jarvis.chatOpen = true }
        .onDisappear { jarvis.chatOpen = false }
        .onChange(of: live.busy) { was, now in
            if was, !now { UINotificationFeedbackGenerator().notificationOccurred(.success); toast = FlowToast(text: "Terminou ✓ " + String((live.lastReply ?? "").prefix(70))) }
        }
        .animation(.spring(duration: 0.25), value: suggestions.count)
        .animation(.spring(duration: 0.3), value: attachName)
        .task {
            while !Task.isCancelled {
                await jarvis.load(session.id)
                try? await Task.sleep(for: .seconds(live.busy ? 2 : 5))
            }
        }
        .confirmationDialog("A sessão está ocupada. Mandar na mesma? Fica na fila do agente.", isPresented: $confirm, titleVisibility: .visible) {
            Button("Enviar") { tick(); Task { await send(force: true) } }
            Button("Cancelar", role: .cancel) {}
        }
    }

    @ViewBuilder private func bubble(_ m: Jarvis.Message) -> some View {
        if m.role == "tool", let path = Self.toolImage(m.text) { // imagem que o agente abriu ou viu (browser, ecrã)
            MediaThumb(path: path) { d, n in withAnimation(.spring(duration: 0.3)) { attach = d; attachName = n } }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if m.role == "tool", m.text.hasPrefix("Desc · ") {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 12, weight: .light)).foregroundStyle(Theme.orange).frame(width: 16)
                Text(String(m.text.dropFirst(7))).font(Theme.sans(14)).foregroundStyle(Theme.ink.opacity(0.7)).lineLimit(3)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if m.role == "tool" {
            let parts = m.text.components(separatedBy: " · ")
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: Self.toolIcon(parts.first ?? "")).font(.system(size: 12, weight: .light)).foregroundStyle(Theme.orange).frame(width: 16)
                (Text(parts.first ?? "").font(.system(size: 13, weight: .semibold, design: .monospaced))
                 + Text(parts.count > 1 ? "  " + parts.dropFirst().joined(separator: " · ") : "").font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.ink.opacity(0.6)))
                    .lineLimit(3)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else { textBubble(m) }
    }

    static func toolImage(_ t: String) -> String? {
        for p in ["Image · ", "Read · "] where t.hasPrefix(p) {
            let path = String(t.dropFirst(p.count))
            if path.hasPrefix("/"), ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains((path as NSString).pathExtension.lowercased()) { return path }
        }
        return nil
    }

    static func toolIcon(_ n: String) -> String {
        switch n {
        case "Bash": "terminal"; case "Edit", "Write", "MultiEdit", "NotebookEdit": "pencil"; case "Read": "doc.text"
        case "Grep", "Glob", "ToolSearch": "magnifyingglass"; case "Agent", "Task": "person.2"; case "WebFetch", "WebSearch": "globe"
        default: "wrench.and.screwdriver"
        }
    }

    @ViewBuilder private func textBubble(_ m: Jarvis.Message) -> some View {
        plainBubble(m)
        let media = Jarvis.mediaPaths(m.text) // também as fotos que mandaste do iPhone
        if !media.isEmpty {
            MediaStrip(paths: media) { d, n in withAnimation(.spring(duration: 0.3)) { attach = d; attachName = n } }
        }
    }

    private func plainBubble(_ m: Jarvis.Message) -> some View {
        let mine = m.role == "user"
        return HStack {
            if mine { Spacer(minLength: 40) }
            RichText(text: Self.trim(m.text))
                .padding(12).background(mine ? Theme.lilac : .white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .textSelection(.enabled)
            if !mine { Spacer(minLength: 40) }
        }
    }

    /// Código colapsado: no telemóvel só interessa a prosa.
    static func trim(_ t: String) -> String {
        return t.count > 2500 ? String(t.prefix(2500)) + "…" : t
    }

    static let models = [("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku")]
    static let modes = [("Normal", "default"), ("Aceitar edições", "acceptEdits"), ("Planear", "plan"), ("Sem perguntas", "bypassPermissions")]
    private func setMode(_ m: String) async {
        tick()
        guard let r = await mac.jarvis(.init(op: "mode", id: session.id, text: m), timeout: 20) else { toast = FlowToast(text: "O Mac não respondeu", ok: false); return }
        if r.ok { toast = FlowToast(text: "Modo: " + (Self.modes.first { $0.1 == m }?.0 ?? m)); await jarvis.refresh() }
        else { toast = FlowToast(text: r.error ?? "Falhou", ok: false) }
    }
    static let efforts = [("Baixo", "low"), ("Médio", "medium"), ("Alto", "high"), ("Máximo", "max")]

    private var modelLabel: String { UserDefaults.standard.string(forKey: "jarvis.model." + session.id) ?? "Modelo" }
    private var effortLabel: String { UserDefaults.standard.string(forKey: "jarvis.effort." + session.id) ?? "" }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !suggestions.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions, id: \.self) { c in
                            let p = c.components(separatedBy: "\t")
                            Button { tick(); pick(p[0]) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p[0]).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
                                    if p.count > 1, !p[1].isEmpty { Text(p[1]).font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(1) }
                                }.padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 260)
                .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            // ponytail: sem fila fixa de comandos; ao escrever "/" aparece a lista filtrada (como no Claude Code).
            VStack(alignment: .leading, spacing: 10) {
                if let a = attach, let n = attachName {
                    AttachPreview(data: a, name: n) { withAnimation(.spring(duration: 0.3)) { attach = nil; attachName = nil } }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if dictating {
                    // A ouvir: a mesma onda da aba Mac e o texto a aparecer em tempo real, numa caixa maior.
                    VStack(alignment: .leading, spacing: 10) {
                        FlowWaveform(level: mic.level, mode: .listening).frame(height: 44).frame(maxWidth: .infinity)
                        Text(mic.text.isEmpty ? "A ouvir… diz o teu prompt" : [draft, mic.text].filter { !$0.isEmpty }.joined(separator: " "))
                            .font(Theme.sans(16)).foregroundStyle(mic.text.isEmpty ? Theme.muted : Theme.ink)
                            .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                            .animation(.easeOut(duration: 0.15), value: mic.text)
                    }.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                } else {
                    TextField(live.busy ? "Adiciona à fila para depois deste" : "Escreve ou dita um prompt", text: $draft, axis: .vertical)
                        .font(Theme.sans(16)).lineLimit(1...6)
                }
                HStack(spacing: 8) {
                    Menu {
                        Button { tick(); withAnimation(.spring(duration: 0.4, bounce: 0.15)) { camera = true } } label: { Label("Câmara", systemImage: "camera") }.onAppear { tick() } // abrir o menu vibra
                        Button { tick(); pickPhoto = true } label: { Label("Fotos", systemImage: "photo.on.rectangle") }
                        Button { tick(); pickFile = true } label: { Label("Ficheiro", systemImage: "doc") }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(Theme.ink)
                            .frame(width: 36, height: 36).background(Theme.appBG, in: Circle())
                    }
                    if live.kind == .claude {
                        Menu {
                            Section("Modelo") { ForEach(Self.models, id: \.1) { m in Button(m.0) { tick(); Task { await command("/model " + m.1, key: "model", label: m.0) } }.onAppear { if m.1 == Self.models.first?.1 { tick() } } } }
                            Section("Effort") { ForEach(Self.efforts, id: \.1) { e in Button(e.0) { tick(); Task { await command("/effort " + e.1, key: "effort", label: e.0) } } } }
                        } label: {
                            (Text(modelLabel).foregroundColor(Theme.ink) + Text(effortLabel.isEmpty ? "" : " " + effortLabel).foregroundColor(Theme.muted))
                                .font(Theme.sans(14, .medium)).padding(.horizontal, 12).frame(height: 36).background(Theme.appBG, in: Capsule())
                        }
                    }
                    if live.kind == .claude, MacSender.paired || !live.id.hasPrefix("pc:") {
                        Menu {
                            ForEach(Self.modes, id: \.1) { m in
                                Button { tick(); Task { await setMode(m.1) } } label: { if (live.mode ?? "default") == m.1 { Label(m.0, systemImage: "checkmark") } else { Text(m.0) } }
                                    .onAppear { if m.1 == Self.modes.first?.1 { tick() } }
                            }
                        } label: {
                            Text(Self.modes.first { $0.1 == (live.mode ?? "default") }?.0 ?? "Normal")
                                .font(Theme.sans(14, .medium)).foregroundStyle(live.mode == "bypassPermissions" ? Theme.orange : Theme.ink)
                                .padding(.horizontal, 12).frame(height: 36).background(Theme.appBG, in: Capsule())
                        }
                    }
                    Spacer()
                    Button { tick(.medium); Task { await toggleDictation() } } label: {
                        Image(systemName: dictating ? "checkmark" : "mic").font(.system(size: 18, weight: .light))
                            .foregroundStyle(dictating ? .white : Theme.ink).frame(width: 36, height: 36)
                            .background(dictating ? Theme.orange : Theme.appBG, in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel(dictating ? "Parar ditado" : "Ditar")
                    // A ditar, a seta envia logo o que disseste (o visto é só para parar e rever o texto à mão).
                    Button { tick(.medium); Task { if dictating { await toggleDictation() }; await send(force: false) } } label: {
                        Image(systemName: sending ? "hourglass" : "arrow.up").font(.system(size: 18, weight: .regular)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(canSend || dictating ? Theme.ink : Theme.disabled, in: Circle())
                    }.buttonStyle(.plain).disabled(!(canSend || dictating) || sending).accessibilityLabel("Enviar")
                }
            }
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 12)
        }
        .padding(.top, 6).padding(.bottom, 14) // colada ao fundo: mais espaço para as mensagens
        .sensoryFeedback(.success, trigger: sending == false && draft.isEmpty)
        .photosPicker(isPresented: $pickPhoto, selection: $photo, matching: .images)

        .onChange(of: photo) { _, item in
            Task {
                guard let item, let d = try? await item.loadTransferable(type: Data.self) else { return }
                // ponytail: JPEG 1600 px chega para o agente ler; foto original (HEIC 5 MB) só se fizer falta.
                let img = UIImage(data: d)
                attach = img.flatMap { Self.shrink($0).jpegData(compressionQuality: 0.75) } ?? d
                attachName = "foto.jpg"; photo = nil
            }
        }
        .fileImporter(isPresented: $pickFile, allowedContentTypes: [.item]) { r in
            guard case let .success(url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: url) { attach = d; attachName = url.lastPathComponent }
        }
    }

    /// Última palavra começa por "/" (ou "mcp:") = mostra a lista filtrada, como no Claude Code.
    private var slashWord: String? {
        guard let w = draft.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init), w.hasPrefix("/") || w.hasPrefix("mcp:") else { return nil }
        return w.lowercased()
    }
    private var suggestions: [String] {
        guard let w = slashWord else { return [] }
        if jarvis.commands.isEmpty { return [jarvis.commandsError.map { "⚠︎ " + $0 + "\t" } ?? "A carregar a lista…\t"] }
        let q = w.hasPrefix("/") ? String(w.dropFirst()) : w
        let all = jarvis.commands
        if q.isEmpty { return Array(all.prefix(200)) }
        func name(_ c: String) -> String { c.lowercased().components(separatedBy: "\t")[0].trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        let starts = all.filter { name($0).hasPrefix(q) }, inside = all.filter { !name($0).hasPrefix(q) && name($0).contains(q) }
        return Array((starts + inside).prefix(60))
    }
    private func pick(_ c: String) {
        if c.hasPrefix("⚠︎") || c.hasPrefix("A carregar") { Task { jarvis.commandsError = nil; await jarvis.loadCommands() }; return }
        var words = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        words.removeLast()
        let ins = c.hasPrefix("mcp:") ? "usa o MCP " + c.dropFirst(4) : c
        draft = (words + [ins]).joined(separator: " ") + " "
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty || attach != nil }

    static func shrink(_ i: UIImage, max: CGFloat = 1600) -> UIImage {
        let k = min(1, max / Swift.max(i.size.width, i.size.height))
        guard k < 1 else { return i }
        return UIGraphicsImageRenderer(size: .init(width: i.size.width * k, height: i.size.height * k)).image { _ in i.draw(in: .init(origin: .zero, size: .init(width: i.size.width * k, height: i.size.height * k))) }
    }

    /// Muda modelo/effort mandando o comando à sessão (Claude Code: /model, /effort).
    private func command(_ c: String, key: String, label: String) async {
        if let e = await jarvis.send(session.id, c) { toast = FlowToast(text: e, ok: false); return }
        UserDefaults.standard.set(label, forKey: "jarvis.\(key).\(session.id)")
        toast = FlowToast(text: label)
    }

    private func send(force: Bool) async {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty || attach != nil else { return }
        if live.busy, !force { confirm = true; return }
        sending = true; defer { sending = false }
        if let e = await jarvis.send(session.id, t, fileName: attachName, file: attach) { UINotificationFeedbackGenerator().notificationOccurred(.error); toast = FlowToast(text: e, ok: false) }
        else { UINotificationFeedbackGenerator().notificationOccurred(.success); draft = ""; attach = nil; attachName = nil; toast = FlowToast(text: "Enviado") }
    }

    /// Ditado: grava aqui, o Whisper do Mac transcreve (modo teste: não cola nada no Mac), o texto fica na caixa.
    private func toggleDictation() async {
        if !dictating {
            let ready = SFSpeechRecognizer.authorizationStatus() == .authorized && AVAudioApplication.shared.recordPermission == .granted
            if !ready, !(await mic.authorize()) { toast = FlowToast(text: "Sem acesso ao microfone", ok: false); return }
            mic.keepAudio = true; mic.start(); withAnimation(.spring(duration: 0.3)) { dictating = mic.isRecording }
            return
        }
        withAnimation(.spring(duration: 0.3)) { dictating = false }
        let preview = await mic.stop()
        let audio = mic.lastAudio; mic.keepAudio = false
        var text = preview
        if audio.count > 8000, let t = await mac.sendAudio(audio, enter: false, paste: false, timeout: 12), !t.isEmpty { text = t }
        draft = [draft, text].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Chamada

/// Áudio da chamada: microfone com cancelamento de eco (voice processing) a 16 kHz para o Mac,
/// e a voz do Jarvis a tocar. `flush()` corta a voz já (barge-in).
final class CallAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private let out16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let play48 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private var playConv: (rate: Int, conv: AVAudioConverter)?
    /// Pico do som que saiu desde a última leitura (diagnóstico "não ouço nada").
    var outPeak: Float = 0
    var playing: Bool { engine.isRunning && player.isPlaying }
    var onMic: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?
    var muted = false
    private(set) var blocks = 0
    private var gain: Float = 6
    private(set) var info = ""

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        // Com CallKit a sessão já vem ativa; um erro aqui não pode matar a chamada.
        do { try s.setActive(true) } catch { info += "setActive: \(error.localizedDescription); " }
        // Microfone do iPhone sempre (como o "Built-in mic" do Wispr): o dos AirPods em HFP chegava mudo.
        if let builtIn = s.availableInputs?.first(where: { $0.portType == .builtInMic }) { try? s.setPreferredInput(builtIn) }
        let input = engine.inputNode
        do { try input.setVoiceProcessingEnabled(true) } catch { info += "VP falhou; " }
        let inFormat = input.outputFormat(forBus: 0)
        info += "\(Int(inFormat.sampleRate)) Hz \(inFormat.channelCount) can."
        converter = AVAudioConverter(from: inFormat, to: out16)
        engine.attach(player)
        // Formato fixo do player: trocar ligações com o motor a correr (voz a 22050 vs 24000) calava a chamada.
        engine.connect(player, to: engine.mainMixerNode, format: play48)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in self?.process(buf) }
        // Com voice processing o iOS só corre o microfone se ele estiver ligado ao grafo: mixer mudo.
        let sink = AVAudioMixerNode(); engine.attach(sink)
        engine.connect(input, to: sink, format: inFormat)
        engine.connect(sink, to: engine.mainMixerNode, format: nil)
        sink.outputVolume = 0
        engine.prepare()
        try engine.start()
        player.play()
        started = true
        observe()
    }

    /// Sem som era isto: o CallKit ativa a sessão / muda a rota (carro, AirPods, altifalante) DEPOIS de o motor
    /// arrancar, o iOS pára o AVAudioEngine em silêncio e os buffers seguintes ficam na fila sem tocar.
    private var observers: [NSObjectProtocol] = []
    private func observe() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in self?.revive("config") },
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] n in
                let t = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
                if t == .ended { self?.revive("interrupção") }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in self?.revive("rota") },
            nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in self?.revive("reset") },
        ]
    }

    /// Volta a pôr o motor e o player a tocar (idempotente).
    func revive(_ why: String = "") {
        guard started else { return } // o CallKit pode ativar o áudio antes de o grafo existir: prepare() num grafo vazio crasha
        if !engine.isRunning { engine.prepare(); do { try engine.start() } catch { info += " · \(why): \(error.localizedDescription)" } }
        if engine.isRunning, !player.isPlaying { player.play() }
        // O iOS apaga o "altifalante" a cada mudança de rota: repor o que a pessoa escolheu.
        if let wantSpeaker, !why.isEmpty { try? AVAudioSession.sharedInstance().overrideOutputAudioPort(wantSpeaker ? .speaker : .none) }
        if !why.isEmpty { route = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ") }
    }
    private(set) var route = ""
    private var started = false

    /// Plano B: sem voice processing (se o microfone continuar mudo com ele).
    func restartWithoutVP() throws {
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        let input = engine.inputNode, f = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: f, to: out16)
        info += " · sem VP \(Int(f.sampleRate)) Hz"
        input.installTap(onBus: 0, bufferSize: 1024, format: f) { [weak self] buf, _ in self?.process(buf) }
        engine.prepare(); try engine.start(); player.play()
    }

    private func process(_ buf: AVAudioPCMBuffer) {
        blocks += 1
        guard let converter, !muted else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 32
        guard let o = AVAudioPCMBuffer(pcmFormat: out16, frameCapacity: cap) else { return }
        var given = false
        converter.convert(to: o, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return buf
        }
        guard let p = o.floatChannelData?[0], o.frameLength > 0 else { return }
        var s = Array(UnsafeBufferPointer(start: p, count: Int(o.frameLength)))
        // Ganho automático: o voice processing do iPhone entrega a voz a ~0,02; o Whisper e o VAD querem ~0,1-0,3.
        let rms = sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(s.count))
        if rms > 0.002 { gain = gain * 0.9 + min(12, max(1, 0.12 / rms)) * 0.1 }
        for i in s.indices { let v = s[i] * gain; s[i] = v > 1 ? 1 : (v < -1 ? -1 : v) }
        onLevel?(min(1, rms * gain))
        onMic?(s)
    }

    func play(_ pcm: Data, rate: Int) {
        let f = CallFrame.floats(pcm)
        guard !f.isEmpty, let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let b = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(f.count)) else { return }
        b.frameLength = AVAudioFrameCount(f.count)
        f.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: f.count) }
        if playConv?.rate != rate { playConv = AVAudioConverter(from: inF, to: play48).map { (rate, $0) } }
        guard let conv = playConv?.conv,
              let o = AVAudioPCMBuffer(pcmFormat: play48, frameCapacity: AVAudioFrameCount(Double(f.count) * 48000 / Double(rate)) + 64) else { return }
        var given = false
        conv.convert(to: o, error: nil) { _, st in
            if given { st.pointee = .noDataNow; return nil }
            given = true; st.pointee = .haveData; return b
        }
        if !engine.isRunning || !player.isPlaying { revive() }
        if let q = o.floatChannelData?[0] { for i in 0..<Int(o.frameLength) { outPeak = max(outPeak, abs(q[i])) } }
        player.scheduleBuffer(o)
    }

    func flush() { player.stop(); player.play() }

    /// Altifalante do iPhone ligado/desligado (desligado = auscultador, ou o carro/auriculares se estiverem ligados).
    func setSpeaker(_ on: Bool) { wantSpeaker = on; try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none) }
    private var wantSpeaker: Bool?
    var onSpeaker: Bool { AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker } }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []; started = false
        engine.inputNode.removeTap(onBus: 0)
        player.stop(); engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

@MainActor final class CallModel: ObservableObject {
    @Published var state = "a ligar"
    @Published var caption = ""
    @Published var heard = ""
    @Published var level: Float = 0
    @Published var muted = false
    @Published var failed: String?
    private let client = CallClient()
    private let audio = CallAudio()

    func start(session: Jarvis.Session, mac: MacSender) async {
        participants = [session]
        client.onEvent = { [weak self] e in Task { @MainActor in self?.apply(e) } }
        client.onAudio = { [weak self] d, r in self?.audio.play(d, rate: r) }
        client.onStop = { [weak self] in self?.audio.flush() }
        client.onEnd = { [weak self] reason in Task { @MainActor in self?.state = "terminada"; if let reason { self?.failed = reason } } }
        if !mac.jarvisReady { await mac.probeJarvis() }
        // Casa / Tailscale primeiro; senão o túnel do relay (chamada de qualquer rede).
        var eps = mac.callEndpoints
        if let ep = await RelayTunnel.endpoint(room: LinkCrypto.room(MacSender.token)) { eps.append(ep) }
        if let err = await client.connect(endpoints: eps, token: MacSender.token, session: session.id) {
            failed = err; state = "falhou"; return
        }
        // Chamada do sistema: aparece no CarPlay e ouve-se no carro; desligar/silenciar no carro chega aqui.
        let car = JarvisCarCall.shared
        car.onEnd = { [weak self] in self?.hangup(); self?.endedBySystem = true }
        car.onMute = { [weak self] m in self?.muted = m; self?.audio.muted = m }
        car.onActivate = { [weak self] in self?.audio.revive("callkit") }
        systemCall = await car.start(name: session.name)
        audio.onMic = { [weak self] s in self?.client.sendMic(s) }
        audio.onLevel = { [weak self] l in Task { @MainActor in self?.level = l } }
        do { try audio.start() } catch { failed = "Microfone indisponível: \(error.localizedDescription)"; client.hangup(); JarvisCarCall.shared.end(); return }
        if systemCall { JarvisCarCall.shared.connected() }
        speaker = audio.onSpeaker
        // Diagnóstico visível: se o microfone não produzir blocos em 3 s, diz porquê.
        try? await Task.sleep(for: .seconds(2))
        if audio.blocks == 0 { try? audio.restartWithoutVP(); try? await Task.sleep(for: .seconds(2)) }
        if audio.blocks == 0 { failed = "Microfone sem som (\(audio.info))" }
        // Diagnóstico para o registo do Mac: o que está mesmo a sair no iPhone.
        while client.onAudio != nil, state != "terminada", !Task.isCancelled {
            let s = AVAudioSession.sharedInstance()
            let d = "saída \(s.currentRoute.outputs.map(\.portName).joined(separator: ",")) vol \(String(format: "%.2f", s.outputVolume)) pico \(String(format: "%.3f", audio.outPeak)) \(audio.playing ? "a tocar" : "PARADO") \(audio.info)"
            audio.outPeak = 0
            if let j = try? JSONSerialization.data(withJSONObject: ["diag": d]) { client.send(.event, j) }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func apply(_ e: CallEvent) {
        switch e.state {
        case "ready": state = "a ouvir"; caption = e.text ?? ""
        case "listening": state = "a ouvir"
        case "heard": heard = e.text ?? ""; state = "a enviar"
        case "thinking": state = "o agente está a trabalhar"
        case "speaking": state = "a falar"; caption = e.text ?? ""
        case "error": failed = e.text
        case "image":
            if let b = e.image.flatMap({ Data(base64Encoded: $0) }), let img = UIImage(data: b) { images.append(img); imageAt = Date() }
        default: break
        }
    }

    /// Imagens que chegaram durante a chamada (captura do ecrã, o que o agente fez). A última fica em destaque.
    @Published var images: [UIImage] = []
    @Published var imageAt = Date.distantPast
    @Published var endedBySystem = false
    @Published var speaker = false
    @Published var participants: [Jarvis.Session] = []
    private var systemCall = false

    func toggleSpeaker() { speaker.toggle(); audio.setSpeaker(speaker) }
    /// Troca de sessão na mesma chamada (como escolher o monitor): o Mac passa a falar só com esta.
    func switchTo(_ s: Jarvis.Session) {
        participants = [s]
        if let d = try? JSONSerialization.data(withJSONObject: ["switch": s.id]) { client.send(.event, d) }
    }

    /// Chamada de grupo: junta outra sessão (o Mac passa a mandar a fala para as duas, ou só para a que chamares pelo nome).
    func add(_ s: Jarvis.Session) {
        guard !participants.contains(where: { $0.id == s.id }) else { return }
        participants.append(s)
        if let d = try? JSONSerialization.data(withJSONObject: ["add": s.id]) { client.send(.event, d) }
    }

    func toggleMute() { muted.toggle(); audio.muted = muted }
    func hangup() { client.hangup(); audio.stop(); if systemCall { systemCall = false; JarvisCarCall.shared.end() } }
}

/// A chamada a decorrer fica aqui (não na vista): minimizar não desliga, como no telefone.
@MainActor final class CallCenter: ObservableObject {
    static let shared = CallCenter()
    @Published private(set) var model: CallModel?
    @Published var shown = false
    private(set) var started = Date()

    /// Botão "Jarvis" do widget (CarPlay): liga à última sessão, sem abrir a app.
    func callLast() {
        guard model == nil, let d = UserDefaults.standard.data(forKey: "jarvis.lastCall"),
              let s = try? JSONDecoder().decode(Jarvis.Session.self, from: d) else { return }
        let mac = KeyboardSession.shared.mac ?? { let m = MacSender(); m.startBrowsing(); return m }()
        call(s, mac: mac); shown = false
    }

    func call(_ s: Jarvis.Session, mac: MacSender) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: "jarvis.lastCall") }
        if model == nil {
            let m = CallModel(); model = m; started = Date()
            Task { await m.start(session: s, mac: mac) }
        }
        shown = true
    }
    func hangup() { model?.hangup(); model = nil; shown = false }
}

struct CallView: View {
    @ObservedObject var call: CallModel
    @ObservedObject var center = CallCenter.shared
    @EnvironmentObject var jarvis: JarvisModel
    @State private var adding = false
    @State private var opened: UIImage?
    /// Chegou imagem: os botões descem uns segundos para a ver; tocar no ecrã trá-los de volta.
    @State private var controlsDown = false

    @State private var start = Date()
    /// Igual à chamada do Jarvis, mas com o pet da sessão e as cores dele (o Jarvis é a bola azul).
    private var seed: Int { SessionPet.slot(call.participants.first?.id ?? "") }
    private var talking: Bool { call.state == "a falar" }

    var body: some View {
        let (top, bottom) = CodePet.palette[seed % 12], level = CGFloat(min(call.level * 6, 0.35))
        let busy = call.state == "a pensar" || call.participants.contains { s in jarvis.sessions.first { $0.id == s.id }?.busy == true }
        ZStack {
            LinearGradient(colors: [bottom.mix(with: .black, by: 0.6), bottom.mix(with: .black, by: 0.15)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 10) {
                HStack {
                    Button { tick(); center.shown = false } label: {
                        Image(systemName: "chevron.down").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 44)
                    }.accessibilityLabel("Minimizar")
                    Spacer()
                }.padding(.horizontal, 12)
                CodePet(seed: seed, busy: busy, active: true).scaleEffect(1.4).frame(width: 70, height: 70)
                // Escolher a sessão sem desligar (para quando vais a andar e não queres olhar muito).
                Menu {
                    ForEach(jarvis.sessions) { s in
                        Button { tick(); call.switchTo(s) } label: {
                            if call.participants.count == 1, call.participants[0].id == s.id { Label(jarvis.title(s), systemImage: "checkmark") }
                            else { Text(jarvis.title(s) + (s.busy ? " · a trabalhar" : "")) }
                        }
                        .onAppear { if s.id == jarvis.sessions.first?.id { tick() } }
                    }
                    Divider()
                    Button { tick(); adding = true } label: { Label("Juntar sessão", systemImage: "person.badge.plus") }
                } label: {
                    HStack(spacing: 6) {
                        Text(call.participants.map { jarvis.title($0) }.joined(separator: " + ")).font(Theme.sans(20, .semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).opacity(0.7)
                    }.foregroundStyle(.white).padding(.horizontal, 30)
                }.accessibilityLabel("Trocar de sessão")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let s = Int(Date().timeIntervalSince(start))
                    Text(String(format: "%d:%02d", s / 60, s % 60)).font(Theme.sans(15)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                ZStack {
                    Circle().fill(top.opacity(0.22)).frame(width: 230, height: 230).scaleEffect(1 + level)
                    CodePet(seed: seed, busy: busy, active: true).scaleEffect(4 * (talking ? 1.04 : 1)).frame(width: 200, height: 200)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: talking)
                }.animation(.spring(duration: 0.15), value: call.level)
                Text(call.failed ?? call.state).font(Theme.sans(16, .medium)).foregroundStyle(.white.opacity(0.85)).padding(.top, 10)
                    .contentTransition(.opacity).animation(.easeOut(duration: 0.2), value: call.state)
                Text(call.caption.isEmpty ? (call.heard.isEmpty ? "" : "Tu: " + call.heard) : call.caption).font(Theme.sans(15)).foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center).lineLimit(call.images.isEmpty ? 4 : 2).padding(.horizontal, 30).frame(minHeight: call.images.isEmpty ? 80 : 44)
                if !call.images.isEmpty { imageStrip }
                Spacer()
                HStack(spacing: 34) {
                    roundButton(call.speaker ? "speaker.wave.3.fill" : "ear", on: call.speaker, label: call.speaker ? "Altifalante" : "Ao ouvido") { call.toggleSpeaker() }
                    Button { tick(); center.hangup() } label: {
                        Image(systemName: "phone.down.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 72, height: 72).background(Color.red, in: Circle())
                    }.accessibilityLabel("Desligar")
                    roundButton(call.muted ? "mic.slash.fill" : "mic.fill", on: call.muted, label: call.muted ? "Silenciado" : "Silenciar") { call.toggleMute() }
                }.padding(.bottom, 40)
                .offset(y: controlsDown ? 220 : 0).opacity(controlsDown ? 0 : 1)
                .animation(.spring(duration: 0.4), value: controlsDown)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if controlsDown { controlsDown = false } }
        .onChange(of: call.imageAt) { _, _ in
            tick(); controlsDown = true
            Task { try? await Task.sleep(for: .seconds(5)); controlsDown = false }
        }
        .fullScreenCover(item: Binding(get: { opened.map(Shown.init) }, set: { opened = $0?.img })) { s in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                ZoomableImage(image: s.img)
                Button { tick(); opened = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.white.opacity(0.2), in: Circle())
                }.padding(16).accessibilityLabel("Fechar")
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: call.state)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: call.endedBySystem) { _, e in if e { center.hangup() } } // desligou no carro
        .sheet(isPresented: $adding) {
            NavigationStack {
                List(jarvis.sessions.filter { s in !call.participants.contains { $0.id == s.id } }) { s in
                    Button { tick(); call.add(s); adding = false } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(jarvis.title(s)).font(Theme.sans(16, .semibold)).foregroundStyle(Theme.ink)
                            Text(s.folder).font(Theme.sans(13)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .navigationTitle("Juntar à chamada").navigationBarTitleDisplayMode(.inline)
            }.presentationDetents([.medium, .large])
        }
    }

    private struct Shown: Identifiable { let img: UIImage; var id: ObjectIdentifier { ObjectIdentifier(img) } }

    /// A última imagem grande; as anteriores em miniatura ao lado. Tocar abre em ecrã inteiro (a chamada continua).
    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(call.images.enumerated().reversed()), id: \.offset) { i, img in
                    let last = i == call.images.count - 1
                    Button { tick(); opened = img } label: {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: last ? 260 : 90, height: last ? 170 : 90).clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.25), lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("Abrir imagem \(i + 1)")
                }
            }.padding(.horizontal, 24)
        }
        .frame(height: 176)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .animation(.spring(duration: 0.35), value: call.images.count)
    }

    private func roundButton(_ icon: String, on: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button { tick(); action() } label: { // como na chamada do Jarvis
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(on ? Color.black : .white)
                    .frame(width: 60, height: 60).background(on ? Color.white : .white.opacity(0.2), in: Circle())
                Text(LocalizedStringKey(label)).font(Theme.sans(12, .medium)).foregroundStyle(.white.opacity(0.85))
            }
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

/// Barra verde no topo com a chamada minimizada (como no telefone): toca para voltar.
struct CallPill: View {
    @ObservedObject var center = CallCenter.shared
    @EnvironmentObject var jarvis: JarvisModel
    var body: some View {
        if let m = center.model, !center.shown {
            Button { tick(); center.shown = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "phone.fill")
                    Text(m.participants.map { jarvis.title($0) }.joined(separator: " + ")).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { t in
                        let s = Int(t.date.timeIntervalSince(center.started))
                        Text(String(format: "%d:%02d", s / 60, s % 60)).monospacedDigit()
                    }
                }
                .font(Theme.sans(14, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 16).frame(height: 36).background(Theme.forest, in: Capsule())
            }
            .buttonStyle(.plain).padding(.top, 4).accessibilityLabel("Voltar à chamada")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// "A trabalhar…" com pontos a pulsar, como o Claude/Codex enquanto o agente corre.
/// "A trabalhar" como no terminal do Claude Code: estrela que roda, verbo que muda e o tempo a contar.
struct WorkingRow: View {
    var since: Date? = nil
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduce
    static let glyphs = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"].map { $0 + "\u{FE0E}" } // FE0E: texto, não emoji (o ✳ saía verde)
    static let verbs = ["A pensar", "A cozinhar", "A magicar", "A matutar", "A congeminar", "A engendrar", "A tricotar", "A esmiuçar", "A burilar", "A desenrascar", "A remexer", "A afinar"]
    var body: some View {
        TimelineView(.periodic(from: .now, by: reduce ? 1 : 0.12)) { t in
            let s = Int(t.date.timeIntervalSince(since ?? start)), k = Int(t.date.timeIntervalSinceReferenceDate / 0.12)
            HStack(spacing: 8) {
                Text(Self.glyphs[reduce ? 4 : k % Self.glyphs.count]).font(.system(size: 17, weight: .bold)).frame(width: 18)
                Text(Self.verbs[(s / 6) % Self.verbs.count] + "…").font(Theme.sans(15, .medium)).contentTransition(.opacity)
                Text("(" + (s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s") + ")").font(Theme.sans(13)).foregroundStyle(Theme.muted).monospacedDigit()
            }
            .foregroundStyle(Theme.orange).animation(.easeInOut(duration: 0.3), value: s / 6)
        }
        .padding(.vertical, 6).onAppear { start = Date() }
        .accessibilityElement(children: .ignore).accessibilityLabel("A trabalhar")
    }
}

/// Volta atrás a arrastar da borda esquerda, mesmo com a barra de navegação escondida (o iOS desliga-o sem isto).
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
        if #available(iOS 26, *) { interactiveContentPopGestureRecognizer?.delegate = self } // o "voltar" a meio do ecrã: na raiz arrastava a lista para o vazio
    }
    public func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard viewControllers.count > 1 else { return false }
        // O pan do "voltar" a meio do ecrã só arranca para a direita: na vertical o ScrollView do chat fica com o gesto.
        guard let p = g as? UIPanGestureRecognizer, let v = p.view else { return true }
        let t = p.translation(in: v), s = p.velocity(in: v)
        let d = abs(t.x) + abs(t.y) > 0 ? t : s
        return d.x > 0 && abs(d.x) > abs(d.y)
    }
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy o: UIGestureRecognizer) -> Bool { false }
}

/// Dentro de uma conversa o arrasto lateral não muda de aba: desliga só o pan do pager das abas (o .scrollDisabled no TabView desligava também o scroll do chat).
struct PagerLock: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ v: UIView, context: Context) {}
    final class Probe: UIView {
        weak var pager: UIScrollView?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { pager?.isScrollEnabled = true; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let w = self.window else { return }
                func find(_ v: UIView) -> UIScrollView? {
                    if let c = v as? UICollectionView, c.isPagingEnabled, c.frame.width >= w.bounds.width - 1 { return c }
                    for s in v.subviews { if let f = find(s) { return f } }
                    return nil
                }
                self.pager = find(w); self.pager?.isScrollEnabled = false
            }
        }
    }
}

/// Háptico curto em cada toque (como o Claude/Codex).
/// .medium por defeito: o .light quase não se sente no iPhone 11 ("os botões não têm haptics").
@MainActor func tick(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
    #if DEBUG
    print("HAPTIC \(style.rawValue)") // ponytail: prova nos testes por cabo (devicectl --console) que o háptico disparou
    #endif
}

/// Markdown do agente como no Claude/Codex: texto com negrito/itálico/código e tabelas desenhadas (não "| a | b |").
struct RichText: View {
    let text: String
    private enum Block: Hashable { case text(String), table([[String]]) }
    private var blocks: [Block] {
        var out: [Block] = [], buf: [String] = [], rows: [[String]] = []
        func flushText() { if !buf.isEmpty { out.append(.text(buf.joined(separator: "\n").trimmingCharacters(in: .newlines))); buf = [] } }
        func flushTable() { if !rows.isEmpty { out.append(.table(rows)); rows = [] } }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|"), t.hasSuffix("|"), t.count > 1 {
                flushText()
                let cells = t.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-:".contains($0) } && !$0.isEmpty }) { rows.append(cells) } // salta |---|---|
            } else { // títulos (#) a negrito e listas (- ) com bolinha, como no Claude
                flushTable()
                if let r = line.range(of: "^#{1,4} ", options: .regularExpression) { buf.append("**" + line[r.upperBound...] + "**") }
                else if let r = line.range(of: "^\\s*[-*] ", options: .regularExpression) { buf.append("•  " + line[r.upperBound...]) }
                else { buf.append(line) }
            }
        }
        flushText(); flushTable()
        return out.filter { if case .text(let s) = $0 { return !s.isEmpty }; return true }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks, id: \.self) { b in
                switch b {
                case .text(let s):
                    Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
                        .font(Theme.sans(15)).foregroundStyle(Theme.ink)
                case .table(let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                                GridRow {
                                    ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                                        Text((try? AttributedString(markdown: c)) ?? AttributedString(c))
                                            .font(Theme.sans(14, i == 0 ? .semibold : .regular)).foregroundStyle(Theme.ink)
                                            .padding(.horizontal, 10).padding(.vertical, 8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .background(i == 0 ? Theme.ink.opacity(0.06) : (i % 2 == 0 ? Theme.ink.opacity(0.025) : .clear))
                                if i < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.ink.opacity(0.12)))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }
}

/// "Mac" ou "PC" em pequeno, só para quem tem os dois ligados.
struct DeviceTag: View {
    let id: String
    @EnvironmentObject var jarvis: JarvisModel
    var body: some View {
        let pc = jarvis.sessions.contains { $0.id.hasPrefix("pc:") }, mac = jarvis.sessions.contains { !$0.id.hasPrefix("pc:") }
        if pc && mac {
            Text(id.hasPrefix("pc:") ? "PC" : "Mac").font(Theme.sans(10, .semibold)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.ink.opacity(0.06), in: Capsule())
        }
    }
}

/// Imagem em ecrã inteiro com pinça para ampliar e duplo toque para repor.
struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var drag: CGSize = .zero
    var body: some View {
        Image(uiImage: image).resizable().scaledToFit()
            .scaleEffect(scale).offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .gesture(MagnifyGesture().onChanged { scale = max(1, base * $0.magnification) }.onEnded { _ in base = scale })
            .simultaneousGesture(DragGesture().onChanged { if scale > 1 { drag = $0.translation } }
                .onEnded { _ in offset.width += drag.width; offset.height += drag.height; drag = .zero })
            .onTapGesture(count: 2) { withAnimation(.spring(duration: 0.3)) { scale = 1; base = 1; offset = .zero } }
    }
}
