import SwiftUI
import AppKit

// Flow Bar da Fala: réplica do pill do Wispr Flow (janela "Status"), medida ao vivo
// (research/compare-mac/pill/wispr) e no CSS extraído (research/wispr-mac/src, NOTES secção C.B).
// Por cima: micro-feedback com dopamina (colar primeiro, celebrar depois, marcos reais, erros calmos).

enum PillState: Equatable { case idle, hover, ptt, handsFree, processing, done, error, toast }

enum FlowEase {
    /// cubic-bezier(0.05, 0.6, 0.4, 0.95) 100ms: o morph de todos os estados no Flow.
    static let morph = Animation.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.1)
    /// Arranque com mola (micro-feedback ao começar a ouvir).
    static let start = Animation.spring(response: 0.26, dampingFraction: 0.62)
    /// Morph do pill para toast (o Flow usa 400ms cubic-bezier(0.4,0,0.2,1) no width/height).
    static let toast = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.32)
    static let tooltip = Animation.easeOut(duration: 0.12)
    static let pop = Animation.spring(response: 0.22, dampingFraction: 0.45)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

struct PillToast: Equatable {
    var text: String
    var action: String?        // "Desfazer"
    var duration: Double
    var celebrate = false
}

@MainActor final class PillModel: ObservableObject {
    @Published var state: PillState = .idle
    @Published var audioScale: CGFloat = 1        // --audio-scale = max(1, 5*s)
    @Published var micActive = false
    @Published var hoverButton: String?            // "cancel" | "stop" | "notes" | "mic"
    @Published var showTip = false                 // tooltip aparece ~150ms depois do hover, como no Flow
    @Published var micToast = false
    @Published var toast: PillToast?
    @Published var toastStart = Date()
    @Published var pop = false
    @Published var goalLeft = 0                    // palavras que faltam para a meta do dia
    var cancelledText = ""
    private var smooth: Double = 0

    /// s = floor(100*(0.85*s + 0.15*level))/100, igual ao hook do Flow, a 60 fps.
    func feed(_ level: Float) {
        smooth = floor(100 * (0.85 * smooth + 0.15 * Double(min(1, level * 4)))) / 100
        audioScale = max(1, 5 * smooth)
        micActive = smooth > 0.02
    }
    func resetLevel() { smooth = 0; audioScale = 1; micActive = false }

    var size: CGSize {
        switch state {
        case .idle: .init(width: 40, height: 8)
        case .hover: .init(width: 50, height: 30)
        case .ptt: .init(width: 73, height: 30)
        case .handsFree: .init(width: 102.5, height: 30)
        case .processing: .init(width: 98, height: 30)
        case .done: .init(width: 73, height: 30)
        case .error: .init(width: 91, height: 30)
        case .toast: .init(width: 0, height: 48)
        }
    }
}

// MARK: Sons próprios (sintetizados, nada copiado do Flow).
enum FlowSound {
    case start, stop, lock, paste, cancel, milestone
    private static var cache: [String: NSSound] = [:]
    static var enabled: Bool { UserDefaults.standard.object(forKey: "fala.sounds") as? Bool ?? true }

    static func play(_ s: FlowSound) {
        guard enabled else { return }
        let key = "\(s)"
        let snd = cache[key] ?? {
            // (frequência inicial, final, duração, volume): glides curtos e suaves, tipo "pluck" de vidro.
            let notes: [(Double, Double, Double, Double)] = switch s {
            case .start: [(587, 880, 0.09, 0.9)]
            case .stop: [(880, 622, 0.09, 0.8)]
            case .lock: [(659, 659, 0.05, 0.7), (988, 988, 0.08, 0.8)]
            case .paste: [(1319, 1319, 0.05, 0.55), (1976, 1976, 0.11, 0.5)]
            case .cancel: [(523, 392, 0.12, 0.6)]
            case .milestone: [(784, 784, 0.07, 0.6), (988, 988, 0.07, 0.6), (1319, 1319, 0.07, 0.6), (1568, 1568, 0.22, 0.7)]
            }
            let n = NSSound(data: wav(notes))!; n.volume = 0.32; cache[key] = n; return n
        }()
        snd.stop(); snd.play()
    }

    private static func wav(_ notes: [(Double, Double, Double, Double)]) -> Data {
        let sr = 44100.0
        var samples: [Int16] = []
        for (f0, f1, d, vol) in notes {
            let n = Int(sr * d)
            var phase = 0.0
            for i in 0..<n {
                let t = Double(i) / sr, u = t / d
                let f = f0 + (f1 - f0) * (1 - pow(1 - u, 3))
                phase += 2 * .pi * f / sr
                let env = min(1, t / 0.003) * exp(-t / (d * 0.38))
                let v = (sin(phase) * 0.78 + sin(2 * phase) * 0.14 + sin(3 * phase) * 0.05) * env * vol
                samples.append(Int16(max(-1, min(1, v)) * 30000))
            }
        }
        samples += [Int16](repeating: 0, count: 600)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        samples.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

// MARK: Controlador: painel, hover, atalho, ditado.
@MainActor final class PillController {
    static let shared = PillController()
    let model = PillModel()
    private var panel: NSPanel!
    private var mic: Transcriber!
    private var store: Store!
    private var timer: Timer?
    private var later: DispatchWorkItem?
    private var tipTask: DispatchWorkItem?
    private let W: CGFloat = 440, H: CGFloat = 320
    static var dailyGoal: Int { max(50, UserDefaults.standard.integer(forKey: "fala.dailyGoal").nonZero ?? 500) }

    func install(mic: Transcriber, store: Store) {
        guard panel == nil else { return }
        self.mic = mic; self.store = store
        let p = NSPanel(contentRect: .init(x: 0, y: 0, width: W, height: H), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true; p.hidesOnDeactivate = false; p.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: FlowBar(ctl: self).environmentObject(model))
        host.frame = p.contentRect(forFrameRect: p.frame)
        p.contentView = host
        panel = p; place(); p.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { _ in MainActor.assumeIsolated { self.tick() } }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Ecrã onde está o rato, centro em baixo (área útil, acima da Dock).
    private func place() {
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.frame else { return }
        let o = NSPoint(x: (f.minX + (f.width - W) / 2).rounded(), y: f.minY)
        if panel.frame.origin != o { panel.setFrameOrigin(o) }
    }

    private func tick() {
        let s = model.state
        let busy = s == .ptt || s == .handsFree || s == .processing
        if busy { model.feed(mic.level) } else if s == .idle || s == .hover { place() }
        let show = UserDefaults.standard.object(forKey: "fala.showBar") as? Bool ?? true
        panel.alphaValue = show || s != .idle ? 1 : 0
        // Zona quente: .hotArea (padding 6px 10px) + folga de 12px como o ::before do Flow.
        let m = NSEvent.mouseLocation, f = panel.frame
        let local = NSPoint(x: m.x - f.minX, y: m.y - f.minY)
        let hw: CGFloat = s == .idle || s == .hover ? 62 : s == .toast ? 150 : model.size.width / 2 + 22
        let hot = NSRect(x: W / 2 - hw, y: 2, width: hw * 2, height: s == .toast ? 72 : 56)
        panel.ignoresMouseEvents = !hot.contains(local)
        if s == .idle && hot.contains(local) { enterHover() }
        else if s == .hover && !hot.contains(local) { leaveHover() }
    }

    private func set(_ s: PillState, _ a: Animation = FlowEase.morph) { withAnimation(a) { model.state = s } }

    private func enterHover() {
        model.goalLeft = max(0, Self.dailyGoal - store.wordsToday)
        set(.hover)
        tipTask?.cancel()
        let t = DispatchWorkItem { [weak self] in withAnimation(FlowEase.tooltip) { self?.model.showTip = true } }
        tipTask = t; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: t)
    }
    private func leaveHover() {
        tipTask?.cancel()
        withAnimation(FlowEase.tooltip) { model.showTip = false }
        set(.idle)
    }

    // Segurar fn = push-to-talk. Dois toques rápidos no fn = mãos livres (podes largar e usar o teclado;
    // com o fn em baixo o Delete vira "apagar à frente"). Em mãos livres, um toque no fn cola.
    private var fnDownAt = Date.distantPast
    private var tapPending = false
    private var ignoreUp = false
    func fnDown() {
        switch model.state {
        case .idle, .hover, .error, .done, .toast: fnDownAt = Date(); tapPending = false; begin(.ptt)
        case .ptt where tapPending:
            // 2.º toque: fica a gravar sem segurar.
            tapPending = false; ignoreUp = true
            set(.handsFree); FlowSound.play(.lock)
            withAnimation(FlowEase.tooltip) { model.micToast = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation(FlowEase.tooltip) { self.model.micToast = false } }
        case .handsFree: ignoreUp = true; finish()
        default: break
        }
    }
    func fnUp() {
        if ignoreUp { ignoreUp = false; return }
        guard model.state == .ptt else { return }
        if Date().timeIntervalSince(fnDownAt) < 0.35 {
            // Toque curto: espera pelo 2.º; se não vier, era um toque sem querer (não cola nada).
            // Espera o intervalo de duplo clique do próprio Mac (~0,5 s): com 0,4 s fixos, um 2.º toque
            // um pouco mais lento fechava a Fala em vez de a deixar a gravar.
            tapPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + min(max(NSEvent.doubleClickInterval, 0.45), 0.7)) { [weak self] in
                guard let self, self.tapPending, self.model.state == .ptt else { return }
                self.tapPending = false
                Task { _ = await self.mic.stop(); self.model.resetLevel() }
                self.set(.idle)
            }
            return
        }
        finish()
    }

    /// Clique no microfone: mãos livres (popo lock).
    func startHandsFree() {
        guard model.state == .hover || model.state == .idle else { return }
        begin(.handsFree)
        FlowSound.play(.lock)
        withAnimation(FlowEase.tooltip) { model.micToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation(FlowEase.tooltip) { self.model.micToast = false } }
    }

    private func begin(_ s: PillState) {
        later?.cancel(); tipTask?.cancel()
        withAnimation(FlowEase.tooltip) { model.showTip = false; model.toast = nil }
        model.resetLevel(); mic.start(); FlowSound.play(.start)
        set(s, FlowEase.start)
        bump()
    }

    /// "Pop" curto (≤300ms) que nunca bloqueia nada.
    private func bump() {
        withAnimation(FlowEase.pop) { model.pop = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { withAnimation(FlowEase.pop) { self.model.pop = false } }
    }

    func finish() {
        guard model.state == .ptt || model.state == .handsFree else { return }
        FlowSound.play(.stop); set(.processing)
        let beforeToday = store.wordsToday, bestWpm = UserDefaults.standard.integer(forKey: "fala.bestWpm")
        Task {
            let t = await mic.stop()
            model.resetLevel()
            guard !t.isEmpty else { showError(); return }
            // 1) colar primeiro
            let out = await MainActor.run { [o = await TechFix.apply(store.process(t))] in ContextFormat.apply(o) }
            Paster.paste(out, enter: false); store.add(out, seconds: mic.seconds)
            // 2) celebrar depois: ✓ verde + som + pop, 300ms
            FlowSound.play(.paste)
            set(.done, FlowEase.pop); bump()
            schedule(0.55) { self.set(.idle) }
            // 3) cerimónia só em marcos reais
            milestone(before: beforeToday, after: store.wordsToday, bestWpm: bestWpm)
        }
    }

    private func milestone(before: Int, after: Int, bestWpm: Int) {
        let marks = [500, 1000, 2000, 5000, 10000]
        var text: String?
        if let m = marks.last(where: { before < $0 && after >= $0 }) {
            text = "\(m.formatted(.number.locale(Locale(identifier: "pt_PT")))) palavras hoje 🎉"
        } else if before < Self.dailyGoal && after >= Self.dailyGoal {
            text = "Meta de hoje cumprida 🎉"
        } else if store.wpm > bestWpm && bestWpm > 0 && store.entries.count > 5 {
            text = "Novo recorde: \(store.wpm) ppm ⚡️"
        }
        if store.wpm > bestWpm { UserDefaults.standard.set(store.wpm, forKey: "fala.bestWpm") }
        guard let text else { return }
        schedule(0.6) {
            FlowSound.play(.milestone)
            self.showToast(PillToast(text: text, action: nil, duration: 2.6, celebrate: true))
        }
    }

    var isRecording: Bool { model.state == .handsFree || model.state == .ptt }

    func cancel() {
        guard model.state == .handsFree || model.state == .ptt else { return }
        FlowSound.play(.cancel)
        showToast(PillToast(text: "Transcrição cancelada", action: "Desfazer", duration: 3))
        Task {
            let t = await mic.stop(); model.resetLevel()
            model.cancelledText = t
        }
    }

    private func showToast(_ t: PillToast) {
        model.toastStart = Date()
        withAnimation(FlowEase.toast) { model.toast = t; model.state = .toast }
        schedule(t.duration) { self.dismissToast() }
    }

    func dismissToast() {
        guard model.state == .toast else { return }
        withAnimation(FlowEase.toast) { model.state = .idle; model.toast = nil }
    }

    func undoCancel() {
        let t = model.cancelledText
        dismissToast()
        guard !t.isEmpty else { return }
        let out = store.process(t); Paster.paste(out, enter: false); store.add(out, seconds: mic.seconds) // repor o cancelado: já estava corrigido
        FlowSound.play(.paste)
    }

    func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private func showError() {
        set(.error)
        schedule(2.2) { if self.model.state == .error { self.set(.idle) } }
    }

    private func schedule(_ s: Double, _ f: @escaping () -> Void) {
        let w = DispatchWorkItem(block: f); later = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }
}

private extension Int { var nonZero: Int? { self == 0 ? nil : self } }

// MARK: Vista.
struct FlowBar: View {
    let ctl: PillController
    @EnvironmentObject var m: PillModel

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            tooltip.frame(height: 34)
            HStack(spacing: 4) {
                pill
                if m.state == .hover { notesButton.transition(.scale(scale: 0.5).combined(with: .opacity)) }
            }
            .padding(.bottom, 14)
        }
        .frame(width: 440, height: 320)
        .font(.figtree(14, weight: 500))
    }

    private var tipText: (String, String?, String?)? {
        if m.micToast { return ("A usar deteção automática (Microfone)", nil, nil) }
        switch m.hoverButton {
        case "cancel": return ("Cancelar", nil, nil)
        case "stop": return ("Terminar e colar", nil, nil)
        case "notes": return ("Abrir a Fala", nil, nil)
        default: break
        }
        if m.state == .hover && m.showTip {
            let goal = m.goalLeft > 0 ? "faltam \(m.goalLeft) palavras" : "meta de hoje ✓"
            return ("Ditar", "fn", goal)
        }
        if m.state == .error { return ("Não ouvi nada. Tenta outra vez", nil, nil) }
        return nil
    }

    @ViewBuilder private var tooltip: some View {
        if let (t, k, sub) = tipText {
            HStack(spacing: 6) {
                Text(t) + Text(k.map { " " + $0 } ?? "").font(.figtree(14, weight: 700))
                if let sub { Text("·").foregroundStyle(.white.opacity(0.4)); Text(sub).foregroundStyle(.white.opacity(0.6)).font(.figtree(13, weight: 500)) }
            }
            .font(.figtree(14, weight: 500)).foregroundStyle(.white).lineLimit(1).fixedSize()
            .padding(.horizontal, 14).frame(height: 32)
            .background(.black, in: Capsule()).overlay(Capsule().strokeBorder(Color(hex: 0x30302f), lineWidth: 1))
            .transition(.opacity.combined(with: .offset(y: 3)))
            .id(t + (sub ?? ""))
        } else { Color.clear }
    }

    private var resting: Bool { m.state == .idle }
    private var radius: CGFloat { resting ? 4 : m.state == .toast ? 24 : 15 }

    private var fill: Color {
        switch m.state {
        case .idle: .black.opacity(0.5)
        case .hover: m.hoverButton == "mic" ? Color(hex: 0x30302f) : Color(hex: 0x30302f)
        case .toast: Color(hex: 0x1a1a1a)
        default: .black
        }
    }
    private var stroke: (Color, CGFloat) {
        switch m.state {
        case .idle: (.white.opacity(0.5), 1)
        case .hover: (Color(hex: 0x5b5b59), 1)
        case .error: (Color(hex: 0xefa249).opacity(0.85), 1.5)   // âmbar calmo, nada de vermelho
        case .done: (Color(hex: 0x4fbf78).opacity(0.7), 1)
        case .toast: (Color(hex: 0x30302f), 1)
        default: (Color(hex: 0x30302f), 1)
        }
    }

    private var pill: some View {
        ZStack {
            switch m.state {
            case .idle: EmptyView()
            case .hover:
                Image(systemName: "mic.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(.white).transition(.opacity)
            case .ptt:
                Waveform(scale: m.audioScale, active: m.micActive)
            case .handsFree:
                HStack(spacing: 0) {
                    BarButton(kind: "cancel", hover: $m.hoverButton) { ctl.cancel() }
                    Spacer(minLength: 0)
                    Waveform(scale: m.audioScale, active: m.micActive)
                    Spacer(minLength: 0)
                    BarButton(kind: "stop", hover: $m.hoverButton) { ctl.finish() }
                }.padding(.horizontal, 6)
            case .processing:
                HStack(spacing: 6) { Waveform(scale: 1, active: false); Spinner() }
            case .done:
                Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color(hex: 0x4fbf78))
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            case .error:
                Image(systemName: "mic.slash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0xffd467))
            case .toast:
                if let t = m.toast { ToastContent(t: t, start: m.toastStart, ctl: ctl).transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.12))) }
            }
        }
        .frame(width: m.state == .toast ? nil : m.size.width, height: m.size.height)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .background(fill, in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke.0, lineWidth: stroke.1))
        .scaleEffect(m.pop ? 1.08 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if m.state == .hover { ctl.startHandsFree() } }
    }

    private var notesButton: some View {
        Button { ctl.openApp() } label: {
            Image(systemName: "record.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black, in: Circle())
                .overlay(Circle().strokeBorder(Color(hex: 0x5b5b59), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { m.hoverButton = $0 ? "notes" : nil }
    }
}

/// Conteúdo do toast (o pill transforma-se nele): texto, botão e barra de tempo em baixo.
struct ToastContent: View {
    let t: PillToast
    let start: Date
    let ctl: PillController
    var body: some View {
        HStack(spacing: 14) {
            Text(t.text).font(.figtree(15, weight: 500)).foregroundStyle(.white).lineLimit(1).fixedSize()
            if let a = t.action {
                Button(a) { ctl.undoCancel() }.buttonStyle(ToastButton())
            }
        }
        .padding(.leading, 20).padding(.trailing, t.action == nil ? 20 : 8)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            TimelineView(.animation) { tl in
                let p = max(0, 1 - tl.date.timeIntervalSince(start) / t.duration)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.white.opacity(0.28))
                        Rectangle().fill(t.celebrate ? Color(hex: 0xf0d7ff) : Color(hex: 0xffffeb)).frame(width: g.size.width * p)
                    }
                }.frame(height: 2.5)
            }
        }
    }
}

/// Botões 18x18 do modo mãos livres: X (sand-950) e check (fundo claro).
struct BarButton: View {
    let kind: String
    @Binding var hover: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: kind == "cancel" ? "xmark" : "checkmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(kind == "cancel" ? Color(hex: 0xfcfcfb) : .black)
                .frame(width: 18, height: 18)
                .background(kind == "cancel" ? Color(hex: 0x4d4a42) : Color(hex: 0xfcfcfb), in: Circle())
                .scaleEffect(hover == kind ? 1.1 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(FlowEase.pop) { hover = h ? kind : (hover == kind ? nil : hover) } }
    }
}

/// 10 barras de 2px, gap 2, envelope 1 - d²/48, keyframe "wave" 1s com atraso a partir do centro.
struct Waveform: View {
    var scale: CGFloat
    var active: Bool
    private let n = 10
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<n, id: \.self) { i in
                    let c = Double(n - 1) / 2, d = abs(Double(i) - c)
                    let env = max(0, 1 - d * d / 48)
                    let off = i < n / 2 ? Double(i) : Double(i - n)
                    let k = Waveform.wave(((t - 0.1 * off).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1))
                    let s = scale > 1.01 ? scale * env * k : 1
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.white.opacity(active ? 1 : 0.4))
                        .frame(width: 2, height: min(18, 2 * s))
                }
            }
            .frame(height: 18)
        }
    }
    /// 0%:1, 20%:1.2, 40%:1.5, 80%:1.1, 90%:1.3, 100%:1 com ease-in-out entre chaves.
    static func wave(_ p: Double) -> Double {
        let keys: [(Double, Double)] = [(0, 1), (0.2, 1.2), (0.4, 1.5), (0.8, 1.1), (0.9, 1.3), (1, 1)]
        for j in 1..<keys.count where p <= keys[j].0 {
            let (a, va) = keys[j - 1], (b, vb) = keys[j]
            let u = (p - a) / (b - a), e = u * u * (3 - 2 * u)
            return va + (vb - va) * e
        }
        return 1
    }
}

/// Spinner de 8 barras 2x5, opacidade .88 a .15 em 1,1s.
struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            ZStack {
                ForEach(0..<8, id: \.self) { i in
                    let ph = (Double(i) / 8 - t + 1).truncatingRemainder(dividingBy: 1)
                    RoundedRectangle(cornerRadius: 1).fill(Color(red: 163 / 255, green: 148 / 255, blue: 199 / 255).opacity(0.15 + 0.73 * ph))
                        .frame(width: 2, height: 5).offset(y: -5.5).rotationEffect(.degrees(Double(i) * 45))
                }
            }.frame(width: 16, height: 16)
        }
    }
}

struct ToastButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.figtree(15, weight: 500))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10).frame(height: 32)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}
