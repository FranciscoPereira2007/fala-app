import SwiftUI

// MARK: - Onda do teclado Flow
/// 10 barras de 5 pt, espaço 8 pt, 5 pt (ponto) a 57 pt. Envelope mais alto ao centro e uma
/// onda que corre da direita para a esquerda (~0,65 s por ciclo). A processar: pontos cinza com ondulação.
struct FlowWaveform: View {
    enum Mode { case idle, listening, processing }
    var level: Float
    var mode: Mode
    /// Tinta das barras (a app é clara; o teclado adapta ao modo escuro).
    var tint = Color(red: 0.102, green: 0.102, blue: 0.102)
    @State private var smooth: CGFloat = 0

    var body: some View {
        TimelineView(.animation(paused: mode == .idle)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                ForEach(0..<10, id: \.self) { i in
                    Capsule()
                        .fill(mode == .processing ? tint.opacity(0.35) : tint)
                        .frame(width: 5, height: height(i, t))
                }
            }
            .frame(height: 60)
        }
        .onChange(of: level) { _, new in
            let v = CGFloat(new)
            smooth = v > smooth ? smooth * 0.4 + v * 0.6 : smooth * 0.82 + v * 0.18
        }
        .onChange(of: mode) { _, m in if m != .listening { smooth = 0 } }
        .onAppear { if mode == .listening { smooth = CGFloat(level) } } // nível fixo (capturas) também mexe
        .animation(.spring(duration: 0.25, bounce: 0.2), value: mode)
    }

    private func height(_ i: Int, _ t: TimeInterval) -> CGFloat {
        switch mode {
        case .idle: return 5
        case .processing:
            let p = (sin(t * 2 * .pi / 0.9 + Double(i) * 0.7) + 1) / 2
            return 5 + 8 * CGFloat(pow(p, 3))
        case .listening:
            let taper = 0.35 + 0.65 * sin(.pi * (Double(i) + 0.5) / 10)
            let travel = 0.55 + 0.45 * sin(t * 2 * .pi / 0.65 + Double(i) * 0.6)
            let amp = max(0.05, min(1, sqrt(Double(smooth))))
            return 5 + 52 * CGFloat(amp * taper * travel)
        }
    }
}

