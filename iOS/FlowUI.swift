import SwiftUI

// Componentes medidos no Wispr Flow iOS (research/compare-ios, NOTES.md "Animações").
extension Theme {
    static let keyboardBG = Color(red: 0.890, green: 0.902, blue: 0.937)   // #E3E6EF
    static let tabPill = Color(red: 0.965, green: 0.965, blue: 0.973)      // #F6F6F8
    static let tabActive = Color(red: 0.890, green: 0.890, blue: 0.898)    // #E3E3E5
    static let tabPurple = Color(red: 0.353, green: 0.239, blue: 0.553)    // #5A3D8D
    static let green = Color(red: 0.310, green: 0.749, blue: 0.467)        // #4FBF77
    static let greenSoft = Color(red: 0.796, green: 0.918, blue: 0.847)    // #CBEAD8
    static let headerBG = Color(red: 0.957, green: 0.949, blue: 0.961)
    static let disabled = Color(red: 0.678, green: 0.671, blue: 0.686)     // #ADABAF
    /// Serif editorial do Flow (EB Garamond, OFL). Itálico para a palavra de ênfase.
    static func garamond(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "EBGaramond-Italic" : "EBGaramond-Regular", size: size).weight(.regular)
    }
    /// Sans geométrica do Flow (Figtree, OFL, fonte variável).
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Figtree-Light", size: size).weight(weight)
    }
}

// MARK: - Painel de gravação (igual ao teclado do Flow)
/// Barra de topo: X branco | dica | check preto (ou mic preto em repouso). Centro: onda + "A ouvir".
struct FlowRecorderPanel: View {
    enum Phase: Equatable { case idle, listening, paused, processing, done(String) }
    var phase: Phase
    var level: Float
    var idleHint = "Toca no microfone para começar"
    var bottomInset: CGFloat = 0
    var start: () -> Void
    var cancel: () -> Void
    var finish: () -> Void
    var pause: (() -> Void)? = nil

    private var live: Bool { phase == .listening || phase == .paused }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if live || phase == .processing {
                    Button(action: { tick(); cancel() }) {
                        Image(systemName: "xmark").font(Theme.sans(16, .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 45, height: 45).background(.white, in: Circle())
                    }.transition(.scale(scale: 0.6).combined(with: .opacity))
                } else { Color.clear.frame(width: 45, height: 45) }
                Spacer(minLength: 8)
                Group {
                    switch phase {
                    case .idle: Text("\(idleHint) →")
                    case .listening: Text("Toca no ✓ para terminar →")
                    case .paused: Text("Em pausa · toca para continuar").onTapGesture { tick(); pause?() }
                    case .processing: Text(" ")
                    case .done(let s): Text(s)
                    }
                }
                .font(Theme.sans(16)).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.8)
                .contentTransition(.opacity)
                Spacer(minLength: 8)
                Button(action: { tick(); (live ? finish : start)() }) {
                    ZStack {
                        Circle().fill(phase == .processing ? Color.white.opacity(0.6) : Theme.ink)
                        switch phase {
                        case .processing: ProgressView().tint(Theme.ink)
                        case .listening, .paused: Image(systemName: "checkmark").font(Theme.sans(17, .semibold)).foregroundStyle(.white)
                        default: Image(systemName: "mic.fill").font(Theme.sans(18)).foregroundStyle(.white)
                        }
                    }.frame(width: 45, height: 45)
                    .contentTransition(.symbolEffect(.replace))
                }
                .disabled(phase == .processing)
            }
            .padding(.horizontal, 12).padding(.top, 12)
            Spacer(minLength: 0)
            FlowWaveform(level: level, mode: phase == .listening ? .listening : (phase == .processing ? .processing : .idle))
                .opacity(phase == .idle || phase == .paused || isDone ? 0.35 : 1)
            VStack(spacing: 2) {
                Text(phase == .processing ? "A processar" : (phase == .listening ? "A ouvir" : phase == .paused ? "Em pausa" : "Pronta"))
                    .font(Theme.sans(15, .semibold))
                    .foregroundStyle(phase == .processing ? Theme.ink.opacity(0.4) : Theme.ink)
                if live { Text("Microfone do iPhone").font(Theme.sans(15, .semibold)) }
            }
            .padding(.top, 10).frame(height: 54, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(height: 250)
        .padding(.bottom, bottomInset)
        .background(Theme.keyboardBG, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .animation(.spring(duration: 0.3, bounce: 0.15), value: phase)
        .sensoryFeedback(.impact(weight: .light), trigger: phase == .listening)
        .sensoryFeedback(.success, trigger: isDone) { _, n in n }
    }
    private var isDone: Bool { if case .done = phase { true } else { false } }
}

// MARK: - Toast "Flow is on"
/// Pill escura #302D36, 48 pt de altura, ícone num círculo verde/vermelho. Desce do topo com mola,
/// fica ~1,6 s e sobe a desvanecer (medido: entra ~0,25 s, sai ~0,3 s).
struct FlowToast: Equatable { var text: String; var ok: Bool = true; var id = UUID() }

struct FlowToastModifier: ViewModifier {
    @Binding var toast: FlowToast?
    var top: CGFloat = 60
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let t = toast {
                HStack(spacing: 10) {
                    Image(systemName: t.ok ? "checkmark" : "minus").font(Theme.sans(12, .heavy)).foregroundStyle(.white)
                        .frame(width: 24, height: 24).background(t.ok ? Theme.green : Color(red: 0.93, green: 0.30, blue: 0.30), in: Circle())
                    Text(t.text).font(Theme.sans(17, .medium)).foregroundStyle(.white)
                }
                .padding(.leading, 14).padding(.trailing, 18).frame(height: 48)
                .background(Theme.primary, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.top, top)
                .id(t.id)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t.id) {
                    try? await Task.sleep(for: .seconds(1.7))
                    withAnimation(.easeIn(duration: 0.3)) { if toast?.id == t.id { toast = nil } }
                }
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.25), value: toast)
        .sensoryFeedback(trigger: toast) { _, n in n == nil ? nil : (n!.ok ? .success : .warning) }
    }
}
extension View { func flowToast(_ t: Binding<FlowToast?>, top: CGFloat = 60) -> some View { modifier(FlowToastModifier(toast: t, top: top)) } }

// MARK: - Cabeçalho das tabs (☰ | título | ação) com linha fina por baixo
struct FlowHeader<Center: View, Trailing: View>: View {
    var menu: (() -> Void)? = nil
    var menuIcon = "line.3.horizontal"
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing
    var body: some View {
        ZStack {
            center
            HStack {
                if let menu {
                    Button(action: { tick(); menu() }) { Image(systemName: menuIcon).font(Theme.sans(20, .medium)).frame(width: 44, height: 44) }
                } else { Color.clear.frame(width: 44, height: 44) }
                Spacer()
                trailing
            }
        }
        .foregroundStyle(Theme.ink).padding(.horizontal, 10).frame(height: 56)
        .background(Theme.headerBG)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.12)).frame(height: 0.5) }
    }
}

/// Logo "|||| Fala": barras de waveform + wordmark.
struct FalaLogo: View {
    var body: some View {
        HStack(spacing: 6) {
            HStack(alignment: .center, spacing: 2.5) {
                ForEach([10.0, 16, 12, 18, 9], id: \.self) { h in Capsule().frame(width: 2.6, height: h) }
            }
            Text("Fala").font(Theme.sans(22, .bold)).tracking(-0.4)
        }
    }
}

/// Banner creme com X (como "Try Flow in any app" / "Flow speaks the way you speak").
struct FlowBanner<Title: View>: View {
    @ViewBuilder var title: Title
    var bodyText: Text
    var cta: LocalizedStringKey
    var ctaStyle: CTAStyle = .full
    var action: () -> Void
    var close: () -> Void
    enum CTAStyle { case full, capsule }
    var body: some View {
        VStack(spacing: 12) {
            title.font(Theme.garamond(29)).multilineTextAlignment(.center).padding(.top, 14)
            bodyText.font(Theme.sans(15)).foregroundStyle(Theme.ink.opacity(0.75)).multilineTextAlignment(.center)
            if ctaStyle == .full {
                Button(cta, action: { tick(); action() }).buttonStyle(DarkButton()).padding(.top, 4)
            } else {
                Button(cta, action: { tick(); action() }).font(Theme.sans(16, .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 40).frame(height: 44).background(Theme.primary, in: Capsule()).padding(.top, 2)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Theme.cream, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button(action: { tick(); close() }) { Image(systemName: "xmark").font(Theme.sans(14, .medium)).foregroundStyle(Theme.ink.opacity(0.6)).frame(width: 40, height: 40) }
        }
        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.95).combined(with: .opacity)))
    }
}

/// FAB preto "+" (Dictionary / Snippets / Scratchpad).
struct FlowFAB: View {
    var action: () -> Void
    var body: some View {
        Button(action: { tick(); action() }) {
            Image(systemName: "plus").font(Theme.sans(24, .medium)).foregroundStyle(.white)
                .frame(width: 58, height: 58).background(Theme.primary, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        }
        .buttonStyle(PressScale())
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}
