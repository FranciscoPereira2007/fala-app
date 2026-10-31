import UIKit
import SwiftUI

/// Teclado Fala, como o do Wispr Flow: "Start" liga a Fala uma vez (abre a app, que fica a ouvir em segundo plano);
/// depois o mic grava SEM sair da app onde estás, e o texto entra sozinho onde está o cursor.
final class KeyboardViewController: UIInputViewController {
    private let model = KBModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.insert = { [weak self] t in self?.textDocumentProxy.insertText(t) }
        model.delete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        model.openApp = { [weak self] in self?.open("fala://start") }
        model.nextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        model.needsGlobe = needsInputModeSwitchKey
        model.hasFull = hasFullAccess
        hasDictationKey = true // o mic é nosso: o iOS esconde o dele (como no Wispr)
        let host = UIHostingController(rootView: KBView(m: model))
        host.view.backgroundColor = .clear
        addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height])
    }

    // Na horizontal fica baixo como o da Apple (~200 pt) para se ver o que está por cima.
    private lazy var height = view.heightAnchor.constraint(equalToConstant: 286)
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let landscape = view.window.map { $0.bounds.width > $0.bounds.height } ?? (UIScreen.main.bounds.width > UIScreen.main.bounds.height)
        if model.compact != landscape { model.compact = landscape; kbKeyHeight = landscape ? 34 : 46 }
        height.constant = landscape ? 200 : 286
    }

    // Enquanto o teclado está à vista pergunta o estado à app (~12x/s, só loopback: a onda fica fluida).
    private var poll: Timer?
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let rk = textDocumentProxy.returnKeyType ?? .default
        model.returnIcon = [.search: "magnifyingglass", .google: "magnifyingglass", .yahoo: "magnifyingglass", .send: "arrow.up", .go: "arrow.right", .done: "checkmark", .next: "arrow.right", .join: "arrow.right", .route: "arrow.right", .continue: "arrow.right"][rk] ?? "return"
        model.returnBlue = model.returnIcon != "return"
        model.ask("state")
        poll = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.model.ask("state") } }
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); poll?.invalidate() }

    /// Teclados não têm extensionContext.open: sobe pela cadeia de responders até à UIApplication.
    private func open(_ s: String) {
        guard let url = URL(string: s) else { return }
        var cur: UIResponder? = self
        while let r = cur {
            if let app = r as? UIApplication { app.open(url); return }
            cur = r.next
        }
    }
}

/// Altura das teclas (46 na vertical, 34 na horizontal). ponytail: global lido no body; muda junto com KBModel.compact, que redesenha.
@MainActor var kbKeyHeight: CGFloat = 46

@MainActor final class KBModel: ObservableObject {
    @Published var phase = "idle"       // idle | listening | processing | done | error
    @Published var session = false
    @Published var level: Float = 0
    @Published var message = ""
    enum Layout { case numbers, letters, symbols }
    @Published var layout = Layout.numbers
    @Published var compact = false // horizontal: teclas mais baixas
    @Published var shift = false
    var returnIcon = "return"
    var returnBlue = false
    func cased(_ k: String) -> String { shift ? k.uppercased() : k }
    var insert: (String) -> Void = { _ in }
    var delete: () -> Void = {}
    var openApp: () -> Void = {}
    var nextKeyboard: () -> Void = {}
    var needsGlobe = true
    var hasFull = false
    private var lastInserted = 0.0

    private var asking = false
    func ask(_ cmd: String) {
        if cmd == "state" && asking { return }
        asking = true
        KeyboardBridge.ask(cmd) { [weak self] s in MainActor.assumeIsolated { self?.asking = false; self?.apply(s ?? KeyboardBridge.off) } }
    }

    /// Texto ao vivo já escrito no campo: cada parcial nova corrige só a diferença.
    private var shown = ""
    private func show(_ new: String) {
        let same = zip(shown, new).prefix { $0 == $1 }.count
        for _ in 0..<(shown.count - same) { delete() }
        insert(String(new.dropFirst(same)))
        shown = new
    }

    private func apply(_ s: KeyboardBridge.State) {
        session = s.session
        let pending = UserDefaults.standard.double(forKey: "kb.autoStart")
        if s.session, s.phase == "idle", pending > 0 {
            UserDefaults.standard.removeObject(forKey: "kb.autoStart")
            if Date().timeIntervalSince1970 - pending < 90 { mic(); return }
        }
        level = s.level
        if s.phase == "listening", phase == "listening" || phase == "idle", s.text != shown { show(s.text) }
        if s.phase == "done", s.at > lastInserted, !s.text.isEmpty {
            lastInserted = s.at
            show(s.text + " "); shown = ""
            ask("ack")
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            message = "Inserido ✓"; phase = "idle"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.message == "Inserido ✓" { self.message = "" } }
            return
        }
        phase = s.phase == "done" ? "idle" : s.phase
        if s.phase == "error" { message = s.text; shown = "" }
    }

    func mic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // Sem sessão: abre a app e, ao voltar, começa logo a ouvir (como o Wispr). Guardado em disco porque o teclado é recriado.
        guard session else { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "kb.autoStart"); openApp(); return }
        message = ""; phase = "listening"
        ask("start")
    }
    func done() { UIImpactFeedbackGenerator(style: .light).impactOccurred(); phase = "processing"; ask("stop") }
    func cancel() { UIImpactFeedbackGenerator(style: .light).impactOccurred(); show(""); phase = "idle"; ask("cancel") }
}

private func dyn(_ light: UIColor, _ dark: UIColor) -> Color { Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light }) }
private func gray(_ w: CGFloat) -> UIColor { UIColor(white: w, alpha: 1) }
private let ink = dyn(UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1), .white)   // tinta (inverte no escuro)
private let inkOn = dyn(.white, UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1))  // o que vai por cima da tinta
// Cores medidas no teclado do Wispr (escuro) e no do iOS (claro).
private let keyLight = dyn(.white, gray(0.29))
private let keyDark = dyn(UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1), gray(0.22))
private let panel = dyn(UIColor(red: 0.89, green: 0.902, blue: 0.937, alpha: 1), gray(0.17)) // #E3E6EF, o fundo do painel da app
private let chip = dyn(.white, gray(0.32))
private let blue = Color(UIColor.systemBlue)

struct KBView: View {
    @ObservedObject var m: KBModel
    private var recording: Bool { m.phase == "listening" || m.phase == "processing" }
    var body: some View {
        VStack(spacing: 0) {
            if recording { recorder.transition(.opacity) } else {
                bar.frame(height: m.compact ? 40 : 50)
                keys.transition(.opacity)
            }
        }
        .padding(.horizontal, 3).padding(.bottom, 2)
        .animation(.easeOut(duration: 0.2), value: recording)
    }

    // MARK: barra de cima (☰ e Start/mic), como o Wispr
    private var bar: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Abrir a Fala", systemImage: "arrow.up.forward.app") { m.openApp() }
                if m.session { Button("Desligar a Fala", systemImage: "power", role: .destructive) { m.ask("off") } }
            } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 19, weight: .medium)).foregroundStyle(ink).frame(width: 44, height: 44)
            }
            Spacer(minLength: 0)
            if !m.message.isEmpty { Text(m.message).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1) }
            Button { m.mic() } label: {
                HStack(spacing: 7) {
                    if !m.session { Text("Start").font(.system(size: 17, weight: .semibold)) }
                    Image(systemName: m.session ? "mic.fill" : "waveform").font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(inkOn).padding(.horizontal, m.session ? 0 : 20).frame(minWidth: 44, minHeight: 40)
                .background(ink, in: Capsule())
            }.buttonStyle(.plain)
        }.padding(.horizontal, 4)
    }

    // MARK: a gravar: igual ao painel da app (FlowRecorderPanel), ocupa o teclado todo
    private var recorder: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                round("xmark", bg: chip, fg: ink) { m.cancel() }
                Spacer(minLength: 8)
                Text(m.phase == "processing" ? " " : "Toca no ✓ para terminar →")
                    .font(.system(size: 16)).foregroundStyle(ink.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                ZStack {
                    Circle().fill(m.phase == "processing" ? chip.opacity(0.6) : ink)
                    if m.phase == "processing" { ProgressView().tint(ink) }
                    else { Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(inkOn) }
                }
                .frame(width: 45, height: 45)
                .onTapGesture { if m.phase == "listening" { m.done() } }
            }
            .padding(.horizontal, 12).padding(.top, 12)
            Spacer(minLength: 0)
            FlowWaveform(level: m.level, mode: m.phase == "processing" ? .processing : .listening, tint: ink)
            VStack(spacing: 2) {
                Text(m.phase == "processing" ? "A processar" : "A ouvir").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(m.phase == "processing" ? ink.opacity(0.4) : ink)
                if m.phase == "listening" { Text("Microfone do iPhone").font(.system(size: 15, weight: .semibold)).foregroundStyle(ink) }
            }
            .padding(.top, 10).frame(height: 54, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.top, 4)
        .animation(.spring(duration: 0.3, bounce: 0.15), value: m.phase)
    }

    // MARK: teclas (números por defeito, como o Wispr; ABC abre as letras, #+= os símbolos)
    private var keys: some View {
        VStack(spacing: m.compact ? 6 : 11) {
            switch m.layout {
            case .letters:
                row(["q","w","e","r","t","y","u","i","o","p"].map(m.cased))
                row(["a","s","d","f","g","h","j","k","l","ç"].map(m.cased))
                HStack(spacing: 6) {
                    special(m.shift ? "shift.fill" : "shift", w: 46) { m.shift.toggle() }
                    Spacer(minLength: 4)
                    HStack(spacing: 6) { ForEach(["z","x","c","v","b","n","m"].map(m.cased), id: \.self) { char($0) } }
                    Spacer(minLength: 4)
                    special("delete.left", w: 46, repeats: true) { m.delete() }
                }
            case .numbers, .symbols:
                row(m.layout == .numbers ? ["1","2","3","4","5","6","7","8","9","0"] : ["[","]","{","}","#","%","^","*","+","="])
                row(m.layout == .numbers ? ["-","/",":",";","(",")","€","&","@","\""] : ["_","\\","|","~","<",">","$","£","¥","•"])
                HStack(spacing: 6) {
                    Button { tap(); m.layout = m.layout == .numbers ? .symbols : .numbers } label: {
                        Text(m.layout == .numbers ? "#+=" : "123").font(.system(size: 15)).keyFace(dark: true)
                    }.buttonStyle(.plain).frame(width: 46)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) { ForEach([".", ",", "?", "!", "'"], id: \.self) { char($0).frame(width: 47) } }
                    Spacer(minLength: 8)
                    special("delete.left", w: 46, repeats: true) { m.delete() }
                }
            }
            HStack(spacing: 6) {
                Button { tap(); m.layout = m.layout == .letters ? .numbers : .letters } label: {
                    Text(m.layout == .letters ? "123" : "ABC").font(.system(size: 16)).keyFace(dark: true)
                }.buttonStyle(.plain).frame(width: 92)
                if m.needsGlobe { special("globe", w: 44) { m.nextKeyboard() } }
                Button { tap(); m.insert(" ") } label: { Text("Fala").font(.system(size: 16)).keyFace() }.buttonStyle(.plain)
                Button { tap(); m.insert("\n") } label: {
                    Image(systemName: m.returnIcon).font(.system(size: 19, weight: .medium))
                        .foregroundStyle(m.returnBlue ? .white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: kbKeyHeight)
                        .background(m.returnBlue ? blue : keyDark, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }.buttonStyle(.plain).frame(width: 128)
            }
        }
        .padding(.top, 2)
    }

    private func row(_ ks: [String]) -> some View { HStack(spacing: 6) { ForEach(ks, id: \.self) { char($0) } } }

    private func char(_ k: String) -> some View {
        Button { tap(); m.insert(k); if m.shift { m.shift = false } } label: { Text(k).font(.system(size: 23)).keyFace() }.buttonStyle(.plain)
    }

    private func special(_ icon: String, w: CGFloat, repeats: Bool = false, _ a: @escaping () -> Void) -> some View {
        Button { tap(); a() } label: { Image(systemName: icon).font(.system(size: 18)).keyFace(dark: true) }
            .buttonStyle(.plain).frame(width: w)
    }

    private func tap() { UIDevice.current.playInputClick(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }

    private func round(_ s: String, bg: Color, fg: Color, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: s).font(.system(size: 20, weight: .bold)).foregroundStyle(fg).frame(width: 52, height: 52).background(bg, in: Circle())
        }.buttonStyle(.plain)
    }
}

private extension View {
    func keyFace(dark: Bool = false) -> some View {
        foregroundStyle(Color.primary).frame(maxWidth: .infinity, minHeight: kbKeyHeight)
            .background(dark ? keyDark : keyLight, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 0, y: 1)
    }
}

