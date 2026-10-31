import SwiftUI
import AVFoundation

/// O teu Jarvis (como o Dot do ChatGPT): um agente sempre disponível no teu Mac ou PC, com memória, que corre com a
/// tua conta do ChatGPT (também grátis) ou do Claude. Aqui: chat e chamada por voz. A voz e o reconhecimento correm
/// no iPhone (sem custos); o computador só pensa e faz o trabalho (Mac: op "dot"; PC: POST /jarvis).
@MainActor final class DotModel: ObservableObject {
    static let shared = DotModel()
    struct Msg: Codable, Identifiable, Equatable { var id = UUID(); var mine: Bool; var text: String; var at = Date() }
    @Published var msgs: [Msg] = Demo.on ? DotModel.demo : (try? JSONDecoder().decode([Msg].self, from: UserDefaults.standard.data(forKey: "dot.msgs") ?? Data())) ?? []
    static let demo: [Msg] = [ // capturas (-fala.demo)
        .init(mine: true, text: "Vê os emails de hoje e diz-me se há alguma coisa urgente."),
        .init(mine: false, text: "Há dois urgentes: a Marta quer a proposta até sexta e o banco pede para confirmares uma transferência. O resto pode esperar."),
        .init(mine: true, text: "Responde à Marta a dizer que segue amanhã de manhã."),
        .init(mine: false, text: "Feito. Respondi à Marta e pus um lembrete para amanhã às 9h."),
    ]
    @Published var thinking = false

    var available: Bool { MacSender.paired || !PCNode.code.isEmpty || Demo.on }
    var whereRuns: String { MacSender.paired ? "no teu Mac" : "no teu PC" }

    private func save() { UserDefaults.standard.set(try? JSONEncoder().encode(Array(msgs.suffix(200))), forKey: "dot.msgs") }

    /// Manda o pedido e espera pela resposta (o trabalho pode levar minutos: vai perguntando).
    func ask(_ text: String, mac: MacSender, onProgress: ((String) -> Void)? = nil) async -> String {
        guard AIConsent.given else { return "Antes de usar o Jarvis, aceita o aviso na aba Sessões." }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        msgs.append(.init(mine: true, text: t)); save(); thinking = true
        defer { thinking = false; save() }
        let reply = await (Demo.on ? "Feito. Marquei a reunião com a Marta para amanhã às 16h e mandei-lhe a proposta." : run(t, mac: mac, onProgress: onProgress))
        msgs.append(.init(mine: false, text: reply))
        return reply
    }

    private func run(_ t: String, mac: MacSender, onProgress: ((String) -> Void)?) async -> String {
        var seen = 0 // mensagens intermédias já entregues
        func feed(_ p: [String]?) { for m in (p ?? []).dropFirst(seen) { onProgress?(m) }; seen = max(seen, p?.count ?? 0) }
        if MacSender.paired, let r = await mac.jarvis(.init(op: "dot", text: t), timeout: 20), let job = r.job {
            for _ in 0..<900 { // até ~10 min
                try? await Task.sleep(for: .milliseconds(700))
                guard let r = await mac.jarvis(.init(op: "dotResult", id: job), timeout: 10) else { continue }
                if r.done == true { return r.reply ?? r.error ?? "Sem resposta" }
                feed(r.progress)
            }
            return "O Jarvis ainda está a trabalhar nisso. Pergunta-lhe daqui a pouco."
        }
        if !PCNode.code.isEmpty, let (s, _, d) = await PCNode.request("POST", "/jarvis", body: try? JSONSerialization.data(withJSONObject: ["text": t]), timeout: 20), s == 200,
           let job = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["job"] as? String {
            for _ in 0..<900 {
                try? await Task.sleep(for: .milliseconds(700))
                if let (s, _, d) = await PCNode.request("GET", "/jarvis?job=" + job, timeout: 10), s == 200,
                   let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    if j["done"] as? Bool == true { return j["reply"] as? String ?? j["error"] as? String ?? "Sem resposta" }
                    feed(j["progress"] as? [String])
                }
            }
            return "O Jarvis ainda está a trabalhar nisso. Pergunta-lhe daqui a pouco."
        }
        return "Não consegui chegar ao teu computador. Tem a Fala aberta?"
    }
}

/// A bolha do Jarvis: círculos que respiram com a voz (a ouvir: o teu microfone; a falar: a voz dele).
struct DotBlob: View {
    var level: CGFloat          // 0...1
    var thinking = false
    var size: CGFloat = 180
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3) { i in
                    let wob: CGFloat = CGFloat(sin(t * (1.3 + Double(i) * 0.4) + Double(i)) * 0.06)
                    let spin = thinking ? t * 40 * Double(i + 1) : t * 8
                    let width: CGFloat = size * (0.8 + 0.25 * level + wob)
                    let height: CGFloat = size * (0.76 + 0.2 * level - wob)
                    Ellipse()
                        .fill(RadialGradient(colors: [Color(red: 0.62, green: 0.75, blue: 1), Color(red: 0.25, green: 0.4, blue: 1).opacity(0.85)],
                                             center: .topLeading, startRadius: 4, endRadius: size * 0.7))
                        .frame(width: width, height: height)
                        .rotationEffect(.degrees(spin + Double(i) * 50))
                        .opacity(i == 0 ? 1 : 0.35)
                        .blur(radius: i == 0 ? 0 : 14)
                }
                HStack(spacing: size * 0.11) { Capsule().frame(width: size * 0.06, height: size * 0.12); Capsule().frame(width: size * 0.06, height: size * 0.12) }
                    .foregroundStyle(.white.opacity(0.95)).offset(y: -size * 0.04)
            }
            .animation(.spring(duration: 0.25), value: level)
        }
        .frame(width: size * 1.2, height: size * 1.2)
        .accessibilityHidden(true)
    }
}

/// Cartão no topo das Sessões.
struct DotCard: View {
    @ObservedObject var dot = DotModel.shared
    var open: () -> Void
    var call: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            DotBlob(level: 0.15, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text("O teu Jarvis").font(Theme.sans(17, .semibold)).foregroundStyle(.white)
                Text(dot.thinking ? "A trabalhar…" : dot.msgs.last?.text ?? "Pede-lhe qualquer coisa. Corre \(dot.whereRuns).")
                    .font(Theme.sans(13)).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(action: { tick(); call() }) {
                Image(systemName: "phone.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.white.opacity(0.22), in: Circle())
            }.buttonStyle(.plain).accessibilityLabel("Ligar ao Jarvis")
        }
        .padding(14)
        .background(LinearGradient(colors: [Color(red: 0.12, green: 0.2, blue: 0.75), Color(red: 0.2, green: 0.42, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(Rectangle()).onTapGesture(perform: open)
    }
}

/// Chat com o Jarvis.
struct DotChatView: View {
    @EnvironmentObject var mac: MacSender
    @EnvironmentObject var jarvis: JarvisModel
    @ObservedObject var dot = DotModel.shared
    @State private var draft = ""
    var call: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { sp in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if dot.msgs.isEmpty {
                            VStack(spacing: 10) {
                                DotBlob(level: 0.2, size: 110)
                                Text("Olá! Sou o teu Jarvis.").font(Theme.garamond(26))
                                Text("Trabalho \(dot.whereRuns), com a tua conta. Lembro-me do que me dizes. Experimenta: \"Resume-me os emails de hoje\" ou \"Cria uma pasta para o projeto novo\".")
                                    .font(Theme.sans(15)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        ForEach(dot.msgs) { m in
                            Text(m.text).font(Theme.sans(16)).padding(12)
                                .background(m.mine ? Theme.lilac : .white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: m.mine ? .trailing : .leading).id(m.id)
                        }
                        if dot.thinking { WorkingRow().id("t") }
                    }.padding(16)
                }
                .onChange(of: dot.msgs.count) { _, _ in withAnimation { sp.scrollTo(dot.msgs.last?.id, anchor: .bottom) } }
            }
            HStack(spacing: 10) {
                TextField("Pede ao Jarvis…", text: $draft, axis: .vertical).font(Theme.sans(16)).lineLimit(1...5)
                Button { tick(); let t = draft; draft = ""; Task { _ = await dot.ask(t, mac: mac) } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 38, height: 38).background(draft.isEmpty ? Theme.disabled : Theme.ink, in: Circle())
                }.disabled(draft.isEmpty || dot.thinking).accessibilityLabel("Enviar")
            }
            .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 14)
        }
        .ignoresSafeArea(.container, edges: .bottom) // a caixa desce até junto da barra do iPhone
        .background(Theme.appBG.ignoresSafeArea())
        .navigationTitle("O teu Jarvis").navigationBarTitleDisplayMode(.inline)
        .background(PagerLock())
        .onAppear { jarvis.chatOpen = true }      // sem a barra de abas por cima da caixa de texto
        .onDisappear { jarvis.chatOpen = false }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { NavigationLink { DotSettingsView() } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Definições do Jarvis") }
            ToolbarItem(placement: .topBarTrailing) { Button(action: { tick(); call() }) { Image(systemName: "phone.fill") }.accessibilityLabel("Ligar ao Jarvis") }
        }
    }
}

/// Escolher o cérebro do Jarvis: conta (ChatGPT ou Claude), modelo e até onde pode mexer no computador.
/// Mac: op "dotConfig" (text vazio = ler, JSON = gravar). PC: GET/POST /jarvis/config.
struct DotSettingsView: View {
    @EnvironmentObject var mac: MacSender
    @State private var cfg: [String: Any] = [:]
    @State private var loading = true
    private var engine: String { cfg["engine"] as? String ?? "auto" }
    private var model: String { cfg["model"] as? String ?? "" }
    private var access: String { cfg["access"] as? String ?? "computador" }
    private func list(_ e: String) -> [String] { (cfg["models"] as? [String: Any])?[e] as? [String] ?? [] }
    private func logged(_ e: String) -> Bool { (cfg["accounts"] as? [String: Any])?[e] as? Bool ?? false }
    var body: some View {
        Form {
            if loading { HStack { ProgressView(); Text("A perguntar ao computador…").foregroundStyle(Theme.muted) } }
            Section {
                Picker("Conta", selection: bind("engine", engine)) {
                    Text("Automático").tag("auto")
                    Text("ChatGPT" + (logged("codex") ? "" : " (não ligada)")).tag("codex")
                    Text("Claude" + (logged("claude") ? "" : " (não ligada)")).tag("claude")
                }
                Picker("Modelo", selection: bind("model", model)) {
                    Text("O da conta").tag("")
                    ForEach(engine == "claude" ? list("claude") : engine == "codex" ? list("codex") : list("codex") + list("claude"), id: \.self) { Text($0).tag($0) }
                }
            } header: { Text("Cérebro") } footer: { Text("Corre com a tua própria conta. Mudar de modelo começa uma conversa nova (a memória dele fica).") }
            Section {
                Picker("Acesso", selection: bind("access", access)) {
                    Text("Todo o computador").tag("computador")
                    Text("Só a pasta dele").tag("pasta")
                }.pickerStyle(.inline).labelsHidden()
            } header: { Text("Até onde pode mexer") } footer: { Text("Com todo o computador, o Jarvis abre apps, mexe nos teus projetos e manda nas outras sessões, como o Dot. Pede sempre confirmação antes de apagar, pagar ou enviar.") }
            Section {
                NavigationLink { DotVoicePicker() } label: { LabeledContent("Voz do Jarvis", value: DotVoice.voiceName) }
            } header: { Text("Voz") } footer: { Text("Para a voz mais natural (grátis, sem internet): Definições › Acessibilidade › Ler e falar › Vozes › Português › Voz › descarrega a Joana (melhorada).") }
        }
        .navigationTitle("Jarvis").navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }
    private func bind(_ k: String, _ v: String) -> Binding<String> {
        Binding(get: { v }, set: { n in cfg[k] = n; if k == "engine" { cfg["model"] = "" }; Task { await save(k == "engine" ? ["engine": n, "model": ""] : [k: n]) } })
    }
    private func load() async {
        defer { loading = false }
        if Demo.on { cfg = ["engine": "codex", "model": "", "access": "computador", "models": ["codex": ["gpt-6-luna", "gpt-6-sol"], "claude": ["sonnet", "opus", "haiku"]], "accounts": ["codex": true, "claude": false]]; return }
        cfg = await fetch(nil) ?? cfg
    }
    private func save(_ c: [String: String]) async { if !Demo.on, let r = await fetch(c) { cfg = cfg.merging(r) { $1 } } }
    private func fetch(_ c: [String: String]?) async -> [String: Any]? {
        let body = c.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        if MacSender.paired, let r = await mac.jarvis(.init(op: "dotConfig", text: body.map { String(decoding: $0, as: UTF8.self) } ?? ""), timeout: 40),
           let d = r.reply?.data(using: .utf8) { return try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
        if !PCNode.code.isEmpty, let (s, _, d) = await PCNode.request(c == nil ? "GET" : "POST", "/jarvis/config", body: body, timeout: 40), s == 200 {
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        return nil
    }
}

/// Chamada com o Jarvis, ao estilo do Dot: ecrã azul, bolha que respira, contador, altifalante, desligar, silenciar.
/// Ouve até a pessoa se calar (1,7 s), pensa no computador, responde em voz (pt-PT do iPhone) e volta a ouvir.
struct DotCallView: View {
    /// Outra sessão (ex.: do PC, sem Mac): nome e como lhe perguntar. nil = o teu Jarvis.
    var title = "Jarvis"
    var ask: ((String) async -> String)? = nil
    @EnvironmentObject var mac: MacSender
    @EnvironmentObject var mic: Transcriber
    @ObservedObject var dot = DotModel.shared
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = DotVoice()
    @State private var state = "A ligar…"
    @State private var muted = false
    @State private var speaker = true
    @State private var start = Date()
    @State private var loop: Task<Void, Never>?
    @State private var lastReply = ""   // só desta chamada

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.12, blue: 0.55), Color(red: 0.13, green: 0.32, blue: 0.95)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 10) {
                DotBlob(level: voice.speaking ? CGFloat(voice.level) : CGFloat(mic.level) * 1.6, thinking: dot.thinking, size: 70).padding(.top, 30)
                Text(title).font(Theme.sans(20, .semibold)).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 30)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let s = Int(Date().timeIntervalSince(start))
                    Text(String(format: "%d:%02d", s / 60, s % 60)).font(Theme.sans(15)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                }
                if !voice.output.isEmpty {
                    Label(voice.output, systemImage: "speaker.wave.2.fill").font(Theme.sans(13, .medium)).foregroundStyle(.white.opacity(0.75))
                        .accessibilityLabel("Som a sair em \(voice.output)")
                }
                if voice.lowVolume {
                    Text("Volume no mínimo: sobe o volume do iPhone").font(Theme.sans(13, .semibold)).foregroundStyle(.yellow)
                }
                Spacer()
                DotBlob(level: voice.speaking ? CGFloat(voice.level) : CGFloat(mic.level) * 1.6, thinking: dot.thinking, size: 200)
                Text(state).font(Theme.sans(16, .medium)).foregroundStyle(.white.opacity(0.85)).padding(.top, 10)
                Text(mic.isRecording ? mic.text : lastReply).font(Theme.sans(15)).foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 30).frame(minHeight: 80)
                Spacer()
                HStack(spacing: 34) {
                    round(speaker ? "speaker.wave.3.fill" : "ear", on: speaker, label: speaker ? "Altifalante" : "Ao ouvido") { speaker.toggle(); voice.route(speaker: speaker) }
                    Button { tick(); hangup() } label: {
                        Image(systemName: "phone.down.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 72, height: 72).background(Color.red, in: Circle())
                    }.accessibilityLabel("Desligar")
                    round(muted ? "mic.slash.fill" : "mic.fill", on: muted, label: muted ? "Silenciado" : "Silenciar") { muted.toggle(); if muted { Task { _ = await mic.stop() } } }
                }.padding(.bottom, 40)
            }
        }
        .overlay(alignment: .top) {
            if voice.basic {
                Text("Voz básica. Para a voz natural e grátis: Definições › Acessibilidade › Ler e falar › Vozes › Português › Voz › Joana (melhorada).")
                    .font(Theme.sans(12)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal, 30).padding(.top, 4)
            }
        }
        .task { mic.callMode = true; begin() }
        .onDisappear { loop?.cancel(); voice.stop(); mic.callMode = false; Task { _ = await mic.stop() } }
    }

    private func round(_ icon: String, on: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: { tick(); action() }) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(on ? Color.black : .white)
                    .frame(width: 60, height: 60).background(on ? Color.white : .white.opacity(0.2), in: Circle())
                Text(LocalizedStringKey(label)).font(Theme.sans(12, .medium)).foregroundStyle(.white.opacity(0.85))
            }
        }.accessibilityLabel(label)
    }

    static let fillers = ["Deixa ver.", "Um segundo.", "Vou já ver isso.", "Ok, já trato.", "Hum, deixa-me pensar.", "Vou ver e já te digo."]

    private func begin() {
        start = Date()
        if Demo.on { state = "A falar…"; return } // capturas: sem microfone nem voz
        loop = Task {
            if !(await mic.authorize()) { state = "Sem acesso ao microfone"; lastReply = "Ativa o microfone da Fala em Definições do iPhone."; return }
            voice.route(speaker: speaker)
            await voice.say("Olá! Diz-me.")
            while !Task.isCancelled {
                if muted { state = "Microfone desligado"; try? await Task.sleep(for: .milliseconds(300)); continue }
                state = "A ouvir…"
                try? await Task.sleep(for: .milliseconds(250)) // deixa a voz acabar de soar antes de abrir o microfone (sem estalo)
                let said = await listen()
                guard !Task.isCancelled else { break }
                if said.isEmpty { continue }
                state = "A pensar…"
                // Como uma pessoa: responde logo ("Deixa ver…") e vai dizendo o que o Jarvis já disse enquanto trabalha.
                let box = TurnBox(); var spoken: [String] = []
                let work = Task { @MainActor in
                    box.result = await (ask != nil ? ask!(said) : dot.ask(said, mac: mac, onProgress: { box.queue.append($0) }))
                }
                await voice.say(Self.fillers.randomElement()!)
                var reply: String?
                while !Task.isCancelled {
                    if let next = box.queue.first {
                        box.queue.removeFirst(); state = "A falar…"
                        let line = SpokenSummary.make(next, maxSentences: 2, maxWords: 35); spoken.append(next)
                        await voice.say(line); state = "A pensar…"
                    } else if let r = box.result { reply = r; break }
                    else { try? await Task.sleep(for: .milliseconds(150)) }
                }
                guard !Task.isCancelled, let reply else { work.cancel(); break }
                state = "A falar…"; lastReply = reply
                if spoken.last?.trimmingCharacters(in: .whitespacesAndNewlines) != reply.trimmingCharacters(in: .whitespacesAndNewlines) {
                    await voice.say(SpokenSummary.make(reply, maxSentences: 3, maxWords: 60))
                }
            }
        }
    }

    /// Ouve até haver fala e depois 1,7 s sem palavras novas (ou 25 s no máximo).
    private func listen() async -> String {
        mic.keepAudio = false; mic.start()
        var last = "", still = Date(), began = Date()
        while !Task.isCancelled && !muted {
            try? await Task.sleep(for: .milliseconds(200))
            if mic.text != last { last = mic.text; still = Date() }
            if !last.isEmpty, Date().timeIntervalSince(still) > 1.7 { break } // pausas curtas a meio da frase não cortam a mensagem
            if Date().timeIntervalSince(began) > 25 { break }
        }
        return await mic.stop().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func hangup() { loop?.cancel(); voice.stop(); Task { _ = await mic.stop() }; dismiss() }
}

/// Voz do Jarvis no iPhone (AVSpeechSynthesizer, a melhor voz pt-PT instalada). Grátis e sem rede.
@MainActor final class DotVoice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    @Published var level: Float = 0
    @Published var basic = false        // só há a voz básica (compacta) instalada
    private var speaker = true
    private let synth = AVSpeechSynthesizer()
    private var done: CheckedContinuation<Void, Never>?
    private var pulse: Task<Void, Never>?
    override init() { super.init(); synth.delegate = self }

    /// Altifalante ou ao ouvido (com auriculares Bluetooth vai para eles).
    /// Uma vez por chamada (e quando se muda altifalante/ouvido): reconfigurar a cada frase dava estalos.
    /// Modo normal (não .voiceChat) e Bluetooth A2DP: o HFP de chamada telefónica deixava a voz rouca e travada.
    func route(speaker: Bool) {
        let s = AVAudioSession.sharedInstance()
        if speaker != self.speaker || s.category != .playAndRecord || !configured {
            self.speaker = speaker; configured = true
            try? s.setCategory(.playAndRecord, mode: .default, options: speaker ? [.defaultToSpeaker, .allowBluetoothA2DP] : [.allowBluetoothA2DP])
            try? s.setActive(true)
        }
        // Sem som era isto: o iOS apaga o "altifalante" a cada mudança de rota (o microfone a abrir muda-a)
        // e a voz ia para auriculares Bluetooth ligados mas fora dos ouvidos. Repor sempre (não dá estalo).
        try? s.overrideOutputAudioPort(speaker ? .speaker : .none)
        output = s.currentRoute.outputs.first?.portName ?? ""
        lowVolume = s.outputVolume < 0.15
    }
    /// Volume do iPhone quase a zero: a chamada "não tem som" e a pessoa não percebe porquê.
    @Published var lowVolume = false
    private var configured = false
    /// Onde a voz está a sair agora (Altifalante, AirPods de…, carro). Mostrado na chamada.
    @Published var output = ""

    /// Melhor voz feminina pt-PT instalada (Premium > Melhorada > básica). A Joana é feminina.
    static var voiceName: String { bestVoice.map { "\($0.name)" + ($0.quality == .premium ? " (Premium)" : $0.quality == .enhanced ? " (Melhorada)" : " (básica)") } ?? "Voz do sistema" }
    static var bestVoice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "dot.voice"), let v = AVSpeechSynthesisVoice(identifier: id) { return v } // escolhida pela pessoa
        let pt = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "pt-PT" }
        let rank = { (v: AVSpeechSynthesisVoice) in v.quality.rawValue * 10 + (v.name.hasPrefix("Catarina") ? 1 : 0) } // empate: a Catarina (a preferida do Fran)
        return pt.filter { $0.gender != .male }.max { rank($0) < rank($1) }
            ?? pt.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "pt-PT")
    }

    func say(_ text: String) async {
        guard !text.isEmpty else { return }
        route(speaker: speaker) // o microfone pode ter mexido no áudio entretanto
        let u = AVSpeechUtterance(string: text)
        u.voice = Self.bestVoice
        basic = (u.voice?.quality ?? .default) == .default
        u.rate = AVSpeechUtteranceDefaultSpeechRate; u.volume = 1
        speaking = true
        pulse = Task { while !Task.isCancelled { level = Float.random(in: 0.25...0.9); try? await Task.sleep(for: .milliseconds(140)) } }
        await withCheckedContinuation { c in done = c; synth.speak(u) }
        pulse?.cancel(); level = 0; speaking = false
    }

    func stop() { synth.stopSpeaking(at: .immediate); finish() }
    private func finish() { done?.resume(); done = nil }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Task { @MainActor in self.finish() } }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { Task { @MainActor in self.finish() } }
}

/// Todas as vozes que o iPhone deixa as apps usar (as da Siri a Apple guarda só para ela). Toque = ouve e escolhe.
struct DotVoicePicker: View {
    @AppStorage("dot.voice") private var chosen = ""
    @State private var synth = AVSpeechSynthesizer()
    private let voices = AVSpeechSynthesisVoice.speechVoices()
        .sorted { ($0.language == "pt-PT" ? 0 : $0.language.hasPrefix("pt") ? 1 : 2, -$0.quality.rawValue, $0.name) < ($1.language == "pt-PT" ? 0 : $1.language.hasPrefix("pt") ? 1 : 2, -$1.quality.rawValue, $1.name) }
    var body: some View {
        List {
            Section { row(nil) } footer: { Text("Automática: a melhor voz de mulher em português de Portugal que tiveres.") }
            Section("Português (Portugal)") { ForEach(voices.filter { $0.language == "pt-PT" }, id: \.identifier) { row($0) } }
            Section("Português (Brasil)") { ForEach(voices.filter { $0.language == "pt-BR" }, id: \.identifier) { row($0) } }
            Section {
                ForEach(voices.filter { !$0.language.hasPrefix("pt") }, id: \.identifier) { row($0) }
            } header: { Text("Outras línguas") } footer: {
                Text("Mais vozes (grátis): Definições › Acessibilidade › Ler e falar › Vozes. As melhores são as \"melhorada\" e \"Premium\".")
            }
        }
        .navigationTitle("Voz").navigationBarTitleDisplayMode(.inline)
        .onDisappear { synth.stopSpeaking(at: .immediate) }
    }
    private func row(_ v: AVSpeechSynthesisVoice?) -> some View {
        Button { tick();
            chosen = v?.identifier ?? ""
            synth.stopSpeaking(at: .immediate)
            let u = AVSpeechUtterance(string: v?.language.hasPrefix("pt") ?? true ? "Olá! Sou o teu Jarvis. Em que posso ajudar?" : "Hi! I'm your Jarvis.")
            u.voice = v ?? DotVoice.bestVoice; synth.speak(u)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(v?.name ?? "Automática").foregroundStyle(Theme.ink)
                    if let v { Text(v.quality == .premium ? "Premium" : v.quality == .enhanced ? "Melhorada" : "Básica").font(.caption).foregroundStyle(Theme.muted) }
                }
                Spacer()
                if chosen == (v?.identifier ?? "") { Image(systemName: "checkmark").foregroundStyle(Theme.purple) }
            }
        }
    }
}

/// Um turno da chamada: o que o Jarvis vai dizendo e a resposta final.
@MainActor final class TurnBox { var queue: [String] = []; var result: String? }
