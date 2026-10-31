import SwiftUI
import UserNotifications

/// Aba "Sessões" do Mac: as sessões Claude Code e Codex vivas, as últimas respostas e uma caixa para mandar prompts.
@MainActor final class SessionsModel: ObservableObject {
    @Published var sessions: [Jarvis.Session] = []
    @Published var selected: String?
    @Published var messages: [Jarvis.Message] = []
    @Published var draft = ""
    @Published var note: String?
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let sel = selected
        Task.detached {
            let list = SessionHub.shared.list()
            let msgs = sel.map { SessionHub.shared.messages($0, limit: 30) } ?? []
            await MainActor.run {
                self.sessions = list
                if self.selected == nil { self.selected = list.first?.id }
                if sel == self.selected { self.messages = msgs }
            }
        }
    }

    func select(_ id: String) { selected = id; messages = []; refresh() }

    func send() {
        guard let id = selected, !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let t = draft; draft = ""
        Task.detached {
            let err = SessionHub.shared.send(id, text: t)
            await MainActor.run { self.note = err?.description ?? "Enviado"; self.refresh() }
        }
    }
}

struct SessionsPage: View {
    @StateObject private var model = SessionsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Sessões", badge: "Jarvis") {
                Text("\(model.sessions.count) a correr").font(.figtree(14)).foregroundStyle(Flow.fg3)
            }
            HStack(alignment: .top, spacing: 16) {
                list.frame(width: 320)
                chat
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            if model.sessions.isEmpty {
                Text("Nenhuma sessão Claude Code ou Codex a correr.").font(.figtree(14)).foregroundStyle(Flow.fg3).padding(16)
            }
            ForEach(model.sessions) { s in
                Button { model.select(s.id) } label: { SessionRow(s: s, selected: model.selected == s.id) }.buttonStyle(.plain)
                if s.id != model.sessions.last?.id { Divider().overlay(Flow.border) }
            }
        }
        .background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Flow.border))
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.messages) { m in MessageBubble(m: m).id(m.id) }
                    }.padding(14)
                }
                .frame(minHeight: 380)
                .onChange(of: model.messages.last?.id) { _, id in if let id { withAnimation(Flow.ease) { proxy.scrollTo(id, anchor: .bottom) } } }
            }
            HStack(spacing: 10) {
                TextField("Escreve um prompt (ou segura Fn e dita)", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.figtree(14)).lineLimit(1...4)
                    .padding(10).background(Flow.bg3, in: RoundedRectangle(cornerRadius: 8))
                    .onSubmit { model.send() }
                Button("Enviar") { model.send() }.buttonStyle(FlowButton(kind: .black, small: true))
                    .disabled(model.selected == nil || model.draft.isEmpty)
            }
            if let n = model.note { Text(n).font(.figtree(12)).foregroundStyle(Flow.fg3) }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Flow.border))
    }
}

struct SessionRow: View {
    let s: Jarvis.Session
    var selected: Bool
    @AppStorage(Mascot.preference) private var mascot = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let pet = Mascot.resolve(mascot, session: s.id) {
                    MascotPreview(id: pet.id, row: s.busy ? 2 : 1, animated: true).frame(width: 38, height: 42)
                }
                Circle().fill(s.needsYou ? Flow.orange : (s.busy ? Flow.teal : Color(hex: 0xc9c6bd))).frame(width: 8, height: 8)
                Text(s.name).font(.figtree(14, weight: 550)).lineLimit(1)
                Spacer()
                Text(s.kind == .claude ? "Claude" : "Codex").font(.figtree(11, weight: 550)).foregroundStyle(Flow.fg3)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Flow.bg3, in: Capsule())
            }
            Text(s.folder + " · " + (s.needsYou ? "precisa de ti" : s.busy ? "a trabalhar" : "livre")).font(.figtree(12)).foregroundStyle(Flow.fg3)
            if let r = s.lastReply, !r.isEmpty { Text(r).font(.figtree(12)).foregroundStyle(Flow.fg).lineLimit(2) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Flow.hoverRow : .clear).contentShape(Rectangle())
    }
}

struct MessageBubble: View {
    let m: Jarvis.Message
    var body: some View {
        let mine = m.role == "user"
        HStack {
            if mine { Spacer(minLength: 60) }
            Text(m.text.count > 1400 ? String(m.text.prefix(1400)) + "…" : m.text)
                .font(.figtree(13)).textSelection(.enabled)
                .padding(10).background(mine ? Flow.lilac : Flow.bg3, in: RoundedRectangle(cornerRadius: 10))
            if !mine { Spacer(minLength: 60) }
        }
    }
}

/// Notificações do Mac quando uma sessão termina ou precisa de aprovação.
enum JarvisNotify {
    static func install() {
        // No Mac é opcional (o Fran já está ao computador); o iPhone recebe sempre os eventos.
        if UserDefaults.standard.bool(forKey: "fala.jarvis.macNotify") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        SessionHub.shared.onEvent = { e in
            guard UserDefaults.standard.bool(forKey: "fala.jarvis.macNotify") else { return }
            let c = UNMutableNotificationContent()
            c.title = e.kind == .finished ? "\(e.sessionName) terminou" : "\(e.sessionName) precisa de ti"
            c.body = e.summary; c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "jarvis.\(e.id)", content: c, trigger: nil))
        }
        SessionHub.shared.startWatching()
    }
}
