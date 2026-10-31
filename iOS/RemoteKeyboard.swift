import SwiftUI
import AVFoundation

/// O teclado do iPhone como teclado do Mac: cada letra vai logo para onde estiver o cursor (em casa ou pela internet).
struct RemoteKeyboardView: View {
    /// compact = barra por cima do teclado normal do iPhone (no ecrã remoto, para o Mac continuar à vista).
    var compact = false
    var pc = false // teclas para o PC (ecrã do PC)
    var onClose: (() -> Void)?
    @EnvironmentObject var mac: MacSender
    @EnvironmentObject var mic: Transcriber
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var dictating = false
    @State private var eraser: Task<Void, Never>?
    @Environment(\.verticalSizeClass) private var vClass // .compact = iPhone na horizontal (barra muda sozinha ao rodar)
    private static let sentinel = " "
    @State private var field = RemoteKeyboardView.sentinel
    @State private var sent = RemoteKeyboardView.sentinel // o que o Mac já tem (para enviar só diferenças)
    @State private var queue: [() async -> Void] = []
    @State private var busy = false
    @State private var status = "Escreve: vai direto para o Mac"
    @FocusState private var focused: Bool

    var body: some View {
        if compact { bar } else { full }
    }

    /// Horizontal: sem teclado do iPhone. Em baixo só as teclas importantes numa linha e o microfone da Fala à direita;
    /// por cima uma faixa branca fina com o texto ao vivo. Tocar na faixa = vertical com o teclado do iPhone.
    /// Vertical: campo + teclas por cima do teclado do iPhone (o da Fala já tem o Start).
    @ViewBuilder private var bar: some View {
        if vClass == .compact { landscapeBar } else { portraitBar }
    }

    private var landscapeBar: some View {
        VStack(spacing: 6) {
            Button { tick(); FalaOrientation.portrait() } label: {
                Text(dictating ? (mic.text.isEmpty ? "A ouvir…" : mic.text) : status)
                    .font(Theme.sans(14)).foregroundStyle(dictating ? .black : .black.opacity(0.55)).lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).frame(height: 30)
                    .background(.white, in: Capsule())
            }.buttonStyle(.plain).accessibilityLabel("Escrever com o teclado do iPhone")
            HStack(spacing: 6) {
                closeButton
                chipRow
                Button { tick(); Task { await dictate() } } label: {
                    // O símbolo da Fala (as barras do logo), não um microfone genérico.
                    HStack(spacing: 6) {
                        HStack(alignment: .center, spacing: 2) {
                            ForEach([8.0, 13, 10, 15, 7], id: \.self) { h in Capsule().frame(width: 2.4, height: dictating ? h * (0.6 + Double(mic.level) * 1.2) : h) }
                        }
                        Text(dictating ? "Parar" : "Fala").font(Theme.sans(15, .bold))
                    }
                    .foregroundStyle(dictating ? .white : .black).padding(.horizontal, 14).frame(height: 34)
                    .background(dictating ? Color.red : .white, in: Capsule())
                    .animation(.easeOut(duration: 0.1), value: mic.level)
                }.accessibilityLabel(dictating ? "Parar e colar no Mac" : "Ditar com a Fala")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.85))
        .onAppear { focused = false; status = "Toca aqui para escrever com o teclado" }
    }

    private var portraitBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Escreve: vai direto para o Mac", text: $field)
                    .focused($focused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(Theme.sans(16)).padding(.horizontal, 12).frame(height: 40)
                    .background(.white, in: Capsule())
                    .onChange(of: field) { old, new in handle(old, new) }
                    .onSubmit { push { await key(key: "return") }; focused = true }
                    .submitLabel(.return)
                closeButton
            }
            chipRow
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.85))
        .task { try? await Task.sleep(for: .milliseconds(400)); focused = true } // depois de rodar, senão o foco perde-se
    }

    private var closeButton: some View {
        Button { tick(); focused = false; onClose?() } label: {
            Image(systemName: "keyboard.chevron.compact.down").foregroundStyle(.white).frame(width: 40, height: 34).background(.white.opacity(0.18), in: Capsule())
        }.accessibilityLabel("Fechar teclado")
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.chips, id: \.0) { k in
                    let face = Text(k.0).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 34)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    if k.1 == "delete", k.2.isEmpty {
                        // ⌫: toque = 1 letra; manter = apaga palavra a palavra, cada vez mais depressa.
                        face.onTapGesture { tick(); push { await key(key: "delete") } }
                            .onLongPressGesture(minimumDuration: 0.4) {} onPressingChanged: { down in
                                eraser?.cancel(); eraser = nil
                                guard down else { return }
                                eraser = Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(400))
                                    var wait = 300
                                    while !Task.isCancelled {
                                        tick(); push { await key(key: "delete", mods: ["opt"]) }
                                        try? await Task.sleep(for: .milliseconds(wait)); wait = max(90, wait - 40)
                                    }
                                }
                            }
                    } else {
                        Button { tick(); push { await key(key: k.1, mods: k.2) } } label: { face }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private static let chips: [(String, String, [String])] = [
        ("⏎", "return", []), ("⇧⏎", "return", ["shift"]), ("⌫", "delete", []), ("espaço", "space", []), ("esc", "escape", []), ("⇥", "tab", []),
        ("←", "left", []), ("↑", "up", []), ("↓", "down", []), ("→", "right", []),
        ("⌘C", "c", ["cmd"]), ("⌘V", "v", ["cmd"]), ("⌘Z", "z", ["cmd"]), ("⌘A", "a", ["cmd"]),
        ("⌘⇥", "tab", ["cmd"]), ("⌘W", "w", ["cmd"]), ("⌘T", "t", ["cmd"]), ("⌃C", "c", ["ctrl"]),
    ]

    /// Microfone da Fala: 1.º toque ouve, 2.º toque manda o áudio ao Mac (Whisper) que cola onde estiver o cursor.
    private func dictate() async {
        if !dictating {
            if AVAudioApplication.shared.recordPermission != .granted, !(await mic.authorize()) { status = "Sem acesso ao microfone"; return }
            mic.keepAudio = true; mic.start(); dictating = mic.isRecording
            return
        }
        dictating = false
        let preview = store.process(await mic.stop())
        let audio = mic.lastAudio; mic.keepAudio = false
        var t = preview, ok = false
        if pc { // ecrã do PC: Whisper no PC e cola lá
            if audio.count > 8000, let w = await PCNode.transcribe(audio, prompt: Array(store.dictionary.values).prefix(40).joined(separator: ", ")) {
                let final = store.process(WhisperEngine.scrub(w)); if !final.isEmpty { t = final }
            }
            if !t.isEmpty { ok = await PCNode.paste(t); store.add(t, toMac: ok, seconds: mic.seconds) }
            status = ok ? "Colado no PC" : "O PC não respondeu"
            return
        }
        if audio.count > 8000, let final = await mac.sendAudio(audio, enter: false, timeout: 12, queueOnFail: false), !final.isEmpty { t = final; ok = true }
        if !ok, !t.isEmpty { ok = await mac.send(t, enter: false) }
        if !t.isEmpty { store.add(t, toMac: ok, seconds: mic.seconds) }
        status = ok ? "Colado no Mac" : (mac.lastError ?? "O Mac não respondeu")
    }

    private var full: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text(status).font(Theme.sans(14)).foregroundStyle(Theme.muted)
                TextField("", text: $field)
                    .focused($focused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(Theme.sans(22)).padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onChange(of: field) { old, new in handle(old, new) }
                    .onSubmit { push { await key(key: "return") }; focused = true }
                    .submitLabel(.return)
                keysRow([("esc", "escape", []), ("⇥", "tab", []), ("⌫", "delete", []), ("⏎", "return", [])])
                keysRow([("←", "left", []), ("↑", "up", []), ("↓", "down", []), ("→", "right", [])])
                keysRow([("⌘C", "c", ["cmd"]), ("⌘V", "v", ["cmd"]), ("⌘Z", "z", ["cmd"]), ("⌘A", "a", ["cmd"])])
                keysRow([("⌘⇥", "tab", ["cmd"]), ("⌘W", "w", ["cmd"]), ("⌘T", "t", ["cmd"]), ("⌃C", "c", ["ctrl"])])
                Spacer()
            }
            .padding(18)
            .background(Theme.appBG.ignoresSafeArea())
            .navigationTitle("Teclado do Mac").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Feito") { tick(); dismiss() } } }
            .onAppear { focused = true }
        }
    }

    private func keysRow(_ ks: [(String, String, [String])]) -> some View {
        HStack(spacing: 10) {
            ForEach(ks, id: \.0) { k in
                Button { tick(); push { await key(key: k.1, mods: k.2) } } label: {
                    Text(k.0).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.buttonStyle(.plain)
            }
        }
    }

    /// O campo espelha o que já foi para o Mac (com 1 espaço à frente para o Delete funcionar com o campo "vazio").
    /// Cada mudança envia só a diferença: Deletes pelo que mudou e o texto novo. Assim as correções do ditado ao vivo
    /// (apagar e reescrever a frase parcial) chegam ao Mac em vez de se colarem repetidas.
    private func handle(_ old: String, _ new: String) {
        if new.isEmpty { push { await key(key: "delete") }; sent = Self.sentinel; field = Self.sentinel; return }
        let (dels, add) = textDiff(sent, new)
        if dels > 0 { push { await key(key: "delete", times: dels) } }
        if !add.isEmpty { push { await key(text: add) } }
        sent = new // ponytail: o campo cresce enquanto a folha está aberta; reabrir limpa
    }

    /// Mac ou PC: o mesmo JSON (o PC traduz ⌘ para Ctrl).
    private func key(text: String? = nil, key: String? = nil, mods: [String] = [], times: Int = 1) async -> Bool {
        guard pc else { return await mac.key(text: text, key: key, mods: mods, times: times) }
        var j: [String: Any] = [:]
        if let text { j["t"] = text }
        if let key { j["k"] = key; j["m"] = mods; j["n"] = times }
        return await PCNode.input(j)
    }

    /// Em fila e por ordem: as letras nunca chegam trocadas.
    private func push(_ f: @escaping () async -> Void) {
        queue.append(f)
        guard !busy else { return }
        busy = true
        Task {
            while !queue.isEmpty {
                let next = queue.removeFirst()
                await next()
            }
            busy = false
            status = mac.lastError == nil ? "Ligado a \(mac.macName ?? "Mac") via \(mac.route ?? "rede")" : (mac.lastError ?? "")
        }
    }
}
