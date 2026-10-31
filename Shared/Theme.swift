import SwiftUI

// Paleta tirada do wisprflow.ai (captura REA): creme, verde-escuro, lilás com borda preta.
enum Theme {
    static let cream = Color(red: 1.0, green: 1.0, blue: 0.93)
    static let ink = Color(red: 0.102, green: 0.102, blue: 0.102)
    static let forest = Color(red: 0.043, green: 0.302, blue: 0.243)
    static let lilac = Color(red: 0.937, green: 0.843, blue: 1.0)
    static let muted = Color(red: 0.42, green: 0.42, blue: 0.38)
    static let appBG = Color(red: 0.957, green: 0.949, blue: 0.961)   // #F4F2F5
    static let primary = Color(red: 0.188, green: 0.176, blue: 0.212) // #302D36
    static let orange = Color(red: 0.996, green: 0.663, blue: 0.275)  // #FEA946
    static let purple = Color(red: 0.663, green: 0.573, blue: 1.0)    // #A992FF
    static let line = Color.black.opacity(0.08)
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        let f = Font.system(size: size, weight: .regular, design: .serif)
        return italic ? f.italic() : f
    }
}

struct LilacButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(Theme.lilac, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.ink, lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// O "pill" do Flow: cápsula preta, X à esquerda, onda branca, check à direita.
struct WavePill: View {
    var level: Float
    var active: Bool
    var done: Bool = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).opacity(active ? 0.6 : 0)
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { i in
                    let seed = abs(sin(Double(i) * 1.7))
                    Capsule().frame(width: 3, height: active ? 5 + CGFloat(level) * 22 * CGFloat(seed) + 3 : 4)
                }
            }
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).opacity(active || done ? 1 : 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).frame(height: 40)
        .background(done ? Theme.forest : Theme.ink, in: Capsule())
        .animation(.spring(duration: 0.18), value: level)
        .animation(.spring(duration: 0.35), value: done)
    }
}

struct DarkButton: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(enabled ? Theme.primary : Color.gray.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}
