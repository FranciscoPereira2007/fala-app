import SwiftUI

/// Aberto pelo teclado Fala (fala://record). Igual ao salto do Wispr: splash escuro com o logo,
/// fundo cinza #C3C3C5, cartão branco "a Fala vai levar-te de volta". Aqui grava logo (o teclado
/// não pode usar o micro), guarda o texto para o teclado e pede para voltar pelo ◀ do iOS.
struct KeyboardRecordView: View {
    var close: () -> Void
    @EnvironmentObject var mic: Transcriber
    @EnvironmentObject var store: Store
    @State private var phase: FlowRecorderPanel.Phase = .idle
    @State private var splash = true

    private let scrim = Color(red: 0.765, green: 0.765, blue: 0.773)   // #C3C3C5 (medido)
    private let okGrey = Color(red: 0.824, green: 0.824, blue: 0.831)  // #D2D2D4

    var body: some View {
        ZStack {
            scrim.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                if isDone { backCard.transition(.scale(scale: 0.9).combined(with: .opacity)) }
                else { liveText.transition(.opacity) }
                Spacer()
                FlowRecorderPanel(phase: phase, level: mic.level, bottomInset: 30, start: begin,
                                  cancel: { Task { _ = await mic.stop(); close() } },
                                  finish: { Task { await finish() } })
                    .offset(y: isDone ? 320 : 0)
            }
            .ignoresSafeArea(edges: .bottom)
            if splash {
                Theme.primary.ignoresSafeArea().overlay { FalaLogo().foregroundStyle(.white).scaleEffect(1.6) }
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: phase)
        .onAppear {
            begin()
            Task { try? await Task.sleep(for: .milliseconds(450)); withAnimation(.easeOut(duration: 0.3)) { splash = false } }
        }
    }

    private var isDone: Bool { if case .done = phase { true } else { false } }

    private var liveText: some View {
        Text(mic.text.isEmpty ? "Fala, o texto entra no campo onde estavas a escrever." : mic.text)
            .font(Theme.sans(20, .semibold)).foregroundStyle(mic.text.isEmpty ? Theme.ink.opacity(0.45) : Theme.ink)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            .padding(24).frame(width: 320)
            .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: mic.text)
    }

    // Cartão 320 pt, raio 28, texto 20 pt semibold à esquerda, botão OK cinza em cápsula (como o Wispr).
    private var backCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Pronto. Toca em ◀ no canto superior esquerdo para voltar à tua app. O texto entra sozinho no campo.")
                .font(Theme.sans(20, .semibold)).foregroundStyle(.black).fixedSize(horizontal: false, vertical: true)
            Button(action: { tick(); close() }) {
                Text("OK").font(Theme.sans(20, .bold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 50).background(okGrey, in: Capsule())
            }.buttonStyle(PressScale())
        }
        .padding(.horizontal, 24).padding(.top, 28).padding(.bottom, 18)
        .frame(width: 320)
        .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func begin() { Task { _ = await mic.authorize(); mic.start(); if mic.isRecording { phase = .listening } } }

    private func finish() async {
        phase = .processing
        let t = store.process(await mic.stop())
        guard !t.isEmpty else { phase = .idle; return }
        store.add(t, seconds: mic.seconds)
        Shared.pending = t
        phase = .done("Pronto 🎉")
    }
}
