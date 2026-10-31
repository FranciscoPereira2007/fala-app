import SwiftUI
import AppKit
import AVFoundation

/// Onboarding do Mac na ordem do Flow (sem login): Registo > Permissões > Configurar > Aprender > Personalizar.
struct RootGate: View {
    @AppStorage("mac.onboarded") private var onboarded = false
    var body: some View {
        ZStack {
            if onboarded { HubView().transition(.opacity) }
            else { MacOnboarding { withAnimation(.easeInOut(duration: 0.3)) { onboarded = true } }.transition(.opacity) }
        }
    }
}

struct MacOnboarding: View {
    var done: () -> Void
    @EnvironmentObject var mic: Transcriber
    @EnvironmentObject var store: Store
    @EnvironmentObject var receiver: MacReceiver
    @State private var step = 0
    @State private var forward = true
    @State private var tried = ""
    @State private var micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var axOK = AXIsProcessTrusted()
    private let sections = ["Registo", "Permissões", "Configurar", "Aprender", "Personalizar"]
    private let stepSection = [1, 2, 2, 3, 4, 4]   // passos -> secção ativa (Registo já feito)
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 44).padding(.horizontal, 60)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    Group { left }
                        .id(step)
                        .transition(.asymmetric(insertion: .offset(x: forward ? 30 : -30).combined(with: .opacity), removal: .opacity))
                    Spacer()
                    HStack {
                        if step > 0 { Button { go(-1) } label: { Image(systemName: "arrow.left") }.buttonStyle(FlowButton(kind: .beige)) }
                        Spacer()
                    }.padding(.bottom, 40)
                }
                .padding(.horizontal, 60).frame(maxWidth: 560, alignment: .leading)
                right.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Flow.bg3, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(20)
            }
        }
        .animation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.28), value: step)
        .font(.figtree(15)).foregroundStyle(Flow.fg).background(Flow.bg)
        .frame(minWidth: 1140, minHeight: 750).environment(\.colorScheme, .light)
        .onReceive(poll) { _ in
            micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let ax = AXIsProcessTrusted()
            if ax, !axOK { NSApp.activate(ignoringOtherApps: true) } // ligou o interruptor: volta sozinho para aqui
            axOK = ax
        }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(sections.indices, id: \.self) { i in
                let cur = stepSection[min(step, stepSection.count - 1)]
                HStack(spacing: 6) {
                    Text(sections[i]).font(.figtree(13, weight: i == cur ? 600 : 450))
                        .foregroundStyle(i <= cur ? Flow.fg : Flow.fg3)
                    if i < sections.count - 1 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Flow.fg3) }
                }
            }
            Spacer()
        }
    }

    private func openPane(_ p: String) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(p)")!) }

    private func go(_ d: Int) { forward = d > 0; step = max(0, min(5, step + d)) }

    private func title(_ a: String, _ b: String = "", _ c: String = "") -> some View {
        Text.accent(a, b, c).font(.garamond(44)).kerning(-0.8).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var left: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch step {
            case 0:
                title(micOK && axOK ? "Obrigado pela confiança. A tua privacidade é sagrada." : "Dá à Fala permissões no teu Mac")
                perm("Deixa a Fala usar o microfone", "A Fala só usa o microfone quando estás a ditar.", micOK) {
                    // Já recusado antes: o macOS não volta a perguntar, abre logo o painel certo.
                    if AVCaptureDevice.authorizationStatus(for: .audio) == .denied { openPane("Privacy_Microphone") }
                    else { Task { _ = await mic.authorize(); micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized } }
                }
                perm("Deixa a Fala escrever por ti", "Assim a Fala põe as tuas palavras na caixa de texto certa.", axOK) {
                    // Como o Wispr: regista a Fala na lista (o prompt) e abre já Acessibilidade, sem a pessoa procurar.
                    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
                    openPane("Privacy_Accessibility")
                }
                if !axOK {
                    Text("Só uma vez: em Acessibilidade, liga o interruptor da Fala. Se não aparecer, carrega em + e escolhe a Fala em Aplicações. Voltas aqui sozinho e o visto fica verde.")
                        .font(.figtree(13)).foregroundStyle(Flow.fg3).frame(maxWidth: 440, alignment: .leading)
                }
                Button(micOK && axOK ? "Continuar" : "Continuar mesmo assim") { go(1) }.buttonStyle(FlowButton(kind: micOK && axOK ? .black : .beige)).padding(.top, 8)
            case 1:
                title("Vamos testar o ", "microfone")
                Text("Diz algo em voz alta. Se as barras mexerem, está a ouvir-te.").foregroundStyle(Flow.fg3)
                Button(mic.isRecording ? "Parar teste" : "Começar teste") {
                    Task { if mic.isRecording { _ = await mic.stop() } else { mic.start() } }
                }.buttonStyle(FlowButton(kind: .beige))
                Button("Continuar") { Task { if mic.isRecording { _ = await mic.stop() }; go(1) } }.buttonStyle(FlowButton())
            case 2:
                title("Segura ", "fn", " e fala")
                Text("Segura a tecla fn enquanto falas. Larga, e o texto aparece onde está o cursor. Para mãos livres, clica no pill em baixo.").foregroundStyle(Flow.fg3)
                Button("Continuar") { go(1) }.buttonStyle(FlowButton())
            case 3:
                title("Experimenta ", "agora")
                Text("Clica na caixa, segura fn e diz: \"Olá, isto é a Fala.\"").foregroundStyle(Flow.fg3)
                if !tried.isEmpty {
                    Label("Escreveste \(tried.split(separator: " ").count) palavras sem tocar no teclado.", systemImage: "checkmark.circle.fill")
                        .font(.figtree(14, weight: 600)).foregroundStyle(Color(hex: 0x2f8f55)).transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                Button(tried.isEmpty ? "Saltar" : "Funcionou, continuar") { go(1) }.buttonStyle(FlowButton(kind: tried.isEmpty ? .beige : .black))
            case 4:
                title("Como queres ", "soar", "?")
                Text("Escolhe o estilo das tuas mensagens. Podes mudar quando quiseres em Style.").foregroundStyle(Flow.fg3)
                Button("Continuar") { go(1) }.buttonStyle(FlowButton())
            default:
                title("Mac quente? Usa o ", "iPhone")
                Text("Aponta a câmara do iPhone ao QR e toca em Abrir na Fala. Fica ligado para sempre.").foregroundStyle(Flow.fg3).lineSpacing(4)
                if let qr = PairQR.image(receiver.pairURL) { Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12)) }
                Button("Começar a usar a Fala") { done() }.buttonStyle(FlowButton())
            }
        }
    }

    @ViewBuilder private var right: some View {
        switch step {
        case 1:
            VStack(spacing: 20) {
                HStack(spacing: 2) { Waveform(scale: max(1, CGFloat(mic.level) * 20), active: mic.isRecording) }
                    .padding(.horizontal, 22).frame(height: 48).background(.black, in: Capsule()).scaleEffect(2)
                Text(mic.text.isEmpty ? " " : mic.text).font(.figtree(15)).foregroundStyle(Flow.fg3).frame(maxWidth: 360)
            }
        case 2:
            HStack(spacing: 14) {
                ForEach(["fn", "⌃", "⌥", "⌘"], id: \.self) { k in
                    Text(k).font(.figtree(22, weight: 550)).foregroundStyle(k == "fn" ? .white : Flow.fg3)
                        .frame(width: 72, height: 72)
                        .background(k == "fn" ? Flow.fg : .white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Flow.border))
                        .scaleEffect(k == "fn" && mic.isRecording ? 0.94 : 1)
                }
            }
        case 3:
            VStack(alignment: .leading, spacing: 10) {
                Text("Nova mensagem").font(.figtree(13, weight: 600)).foregroundStyle(Flow.fg3)
                TextEditor(text: $tried).font(.figtree(16)).scrollContentBackground(.hidden).frame(height: 160)
                    .overlay(alignment: .topLeading) { if tried.isEmpty { Text("Olá, isto é a Fala.").italic().foregroundStyle(Flow.fg3).padding(5).allowsHitTesting(false) } }
            }
            .padding(20).frame(width: 440).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Flow.border))
        case 4:
            HStack(spacing: 12) {
                ForEach(Array(Store.styles.prefix(3)), id: \.0) { s in
                    Button { store.style = s.0 } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(s.0).font(.figtree(14, weight: 600)); Text(s.1).font(.figtree(12)).foregroundStyle(Flow.fg3)
                            Spacer(minLength: 30)
                            Text(s.2).font(.figtree(13)).padding(10).background(Color(hex: 0xfaf5ff), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .padding(14).frame(width: 170, height: 200, alignment: .topLeading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(store.style == s.0 ? Color(hex: 0xa26ec1) : Flow.border, lineWidth: store.style == s.0 ? 2 : 1))
                    }.buttonStyle(.plain)
                }
            }
        case 5:
            Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 90, weight: .light)).foregroundStyle(Flow.fg)
        default:
            ZStack {
                RoundedRectangle(cornerRadius: 22.5).fill(.black).frame(width: 102, height: 30)
                    .overlay(Waveform(scale: 2.5, active: true))
                    .scaleEffect(2.4)
            }
        }
    }

    private func perm(_ t: String, _ d: String, _ ok: Bool, allow: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t).font(.figtree(15, weight: 600))
                Text(d).font(.figtree(13)).foregroundStyle(Flow.fg3)
            }
            Spacer()
            if ok { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Color(hex: 0x4fbf78)).transition(.scale.combined(with: .opacity)) }
            else { Button("Permitir", action: allow).buttonStyle(FlowButton(small: true)) }
        }
        .padding(16).background(Flow.bg3, in: RoundedRectangle(cornerRadius: 12))
        .animation(.spring(duration: 0.3, bounce: 0.3), value: ok)
    }
}
