import SwiftUI
import AppKit

// Peças comuns do hub, copiadas do Flow: cabeçalho, tabs sublinhadas, banner escuro, toggles, modais.

/// Modais por cima da janela inteira (fundo escurecido), como no Flow.
@MainActor final class ModalCenter: ObservableObject {
    @Published var content: AnyView?
    func show(_ v: some View) { withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.28)) { content = AnyView(v) } }
    func close() { withAnimation(.easeOut(duration: 0.15)) { content = nil } }
}

struct ModalHost: ViewModifier {
    @ObservedObject var center: ModalCenter
    func body(content: Content) -> some View {
        content.overlay {
            if let c = center.content {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea().onTapGesture { center.close() }.transition(.opacity)
                    c.foregroundStyle(Flow.fg).transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
        }
        .environmentObject(center)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var badge: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 10) {
            Text(LocalizedStringKey(title)).font(.figtree(24, weight: 550))
            if let badge { BetaBadge(text: badge, dark: true) }
            Spacer()
            trailing()
        }
        .frame(height: 40)
    }
}
extension PageHeader where Trailing == EmptyView {
    init(title: String, badge: String? = nil) { self.title = title; self.badge = badge; self.trailing = { EmptyView() } }
}

struct BetaBadge: View {
    let text: String
    var dark = false
    var body: some View {
        Text(text).font(.figtree(11, weight: 600))
            .foregroundStyle(dark ? .white : Color(hex: 0xa26ec1))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(dark ? Flow.fg : Color(hex: 0xf7ecff), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Tabs com sublinhado animado (matchedGeometry), 14px, cinzento quando inativa.
struct FlowTabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var badges: [T: String] = [:]
    var trailing: AnyView? = nil
    @Namespace private var ns
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(items, id: \.0) { id, label in
                    Button { withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.25)) { selection = id } } label: {
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Text(LocalizedStringKey(label)).font(.figtree(14, weight: selection == id ? 550 : 450))
                                    .foregroundStyle(selection == id ? Flow.fg : Flow.fg.opacity(0.75))
                                if let b = badges[id] { BetaBadge(text: b) }
                            }
                            ZStack {
                                Rectangle().fill(.clear).frame(height: 2)
                                if selection == id { Rectangle().fill(Flow.fg).frame(height: 2).matchedGeometryEffect(id: "u", in: ns) }
                            }
                        }.fixedSize().contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
                if let trailing { trailing }
            }
            Rectangle().fill(Flow.border).frame(height: 1)
        }
    }
}

/// Banner escuro com "foto" desfocada (gradiente nosso), título em EB Garamond com palavra em itálico.
struct FlowBanner<Content: View>: View {
    let title: Text
    var tint: [Color] = [Color(hex: 0x6b4a2a), Color(hex: 0x2a3340), Color(hex: 0x84663e)]
    var onClose: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title.font(.garamond(30)).kerning(-0.5).foregroundStyle(.white)
            content()
        }
        .font(.figtree(14)).foregroundStyle(.white)
        .padding(.horizontal, 24).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color(hex: 0x1a1612)
                GeometryReader { g in
                    ForEach(tint.indices, id: \.self) { i in
                        Circle().fill(tint[i]).frame(width: g.size.width * 0.5)
                            .position(x: g.size.width * [0.85, 0.55, 0.15][i % 3], y: g.size.height * [0.3, 0.9, 0.1][i % 3])
                    }
                }.blur(radius: 80).opacity(0.9)
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(.white.opacity(0.2), in: Circle())
                }.buttonStyle(.plain).padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Botões: preto (primário), bege (secundário), claro dentro de banners.
struct FlowButton: ButtonStyle {
    enum Kind { case black, beige, light, ghost }
    var kind: Kind = .black
    var small = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.figtree(small ? 13 : 14, weight: 550)).lineLimit(1)
            .foregroundStyle(kind == .black ? Color.white : Flow.fg)
            .padding(.horizontal, small ? 10 : 14).frame(height: small ? 28 : 34)
            .background(bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
    private var bg: Color {
        switch kind { case .black: Flow.fg; case .beige: Flow.bg2; case .light: Color(hex: 0xf5f4f0); case .ghost: .clear }
    }
}

struct FlowToggle: View {
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Flow.fg).controlSize(.small).disabled(disabled)
    }
}

struct FlowField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text).textFieldStyle(.plain).font(.figtree(14))
            .padding(.horizontal, 10).frame(height: 36)
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Flow.border, lineWidth: 1))
    }
}

/// Cartão de modal (branco, radius 16, sombra 2xl).
struct ModalCard<Content: View>: View {
    var width: CGFloat = 372
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .foregroundStyle(Flow.fg).environment(\.colorScheme, .light)
            .padding(18).frame(width: width, alignment: .leading)
            .background(Flow.bg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color(hex: 0x1a1a1a).opacity(0.25), radius: 25, y: 25)
    }
}

/// Lista em cartão (linhas separadas por linha bege), como Dictionary/Snippets.
struct CardList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row
    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { i in
                row(i)
                if i.id != items.last?.id { Rectangle().fill(Flow.border).frame(height: 1) }
            }
        }
        .background(Flow.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Flow.border))
    }
}

struct HoverRow<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hover = false
    var body: some View {
        content(hover).background(hover ? Flow.bg3 : .clear)
            .onHover { h in withAnimation(Flow.ease) { hover = h } }
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Flow.fg)
            .padding(.horizontal, 5).frame(height: 18)
            .background(.white, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Flow.border))
    }
}

struct Chip: View {
    let text: String
    var italic = false
    var body: some View {
        Text(text).font(.figtree(13, weight: 550)).italic(italic).foregroundStyle(Flow.fg).lineLimit(1)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Color.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Linha de definições: título, descrição, controlo à direita.
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title)).font(.figtree(14, weight: 550))
                if let detail { Text(LocalizedStringKey(detail)).font(.figtree(13)).foregroundStyle(Flow.fg3).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
    }
}

struct SettingGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0, content: content)
            .background(Flow.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct RowDivider: View { var body: some View { Rectangle().fill(Flow.border).frame(height: 1).padding(.horizontal, 14) } }

extension Text {
    /// "Flow spells the way *you* do." -> itálico só na palavra marcada.
    static func accent(_ a: String, _ b: String, _ c: String) -> Text { Text(a) + Text(b).italic() + Text(c) }
}
