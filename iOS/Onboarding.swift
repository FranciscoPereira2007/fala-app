import SwiftUI

/// Onboarding na ordem do Flow: intro, quiz, resposta, testar a magia (ditado real), streak, estilo, pronto.
struct Onboarding: View {
    var done: () -> Void
    @EnvironmentObject var mic: Transcriber
    @EnvironmentObject var store: Store
    @State private var step = 0
    @State private var picks: Set<Int> = []
    @State private var tried = ""
    private let total = 9

    private let quiz = [("bubble.left", "Não consigo acompanhar as mensagens"), ("envelope", "Escrever emails demora imenso"),
                        ("sparkles", "Quero falar com IA mais depressa"), ("lightbulb", "Perco ideias por não as apontar"),
                        ("laptopcomputer", "O meu Mac aquece e deixa de me ouvir"), ("keyboard", "Quero escrever mais rápido no telemóvel")]

    var body: some View {
        VStack(spacing: 0) {
            if step > 0 {
                // Barra segmentada do Flow: segmentos com preenchimento que desliza.
                HStack(spacing: 10) {
                    Button { tick(); withAnimation { step -= 1 } } label: { Image(systemName: "chevron.left").font(Theme.sans(19, .medium)).frame(width: 28, height: 44) }
                    ForEach(1..<total, id: \.self) { i in
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.black.opacity(0.12))
                                Capsule().fill(Theme.primary).frame(width: i <= step ? g.size.width : 0)
                            }
                        }.frame(height: 4)
                    }
                    if step == 5, tried.isEmpty { Button("Saltar") { tick(); next() }.font(Theme.sans(16)).foregroundStyle(Theme.muted).fixedSize() }
                }.padding(.horizontal, 20).padding(.top, 4)
            }
            Group {
                switch step {
                case 0: intro
                case 1: quizView
                case 2: personalized
                case 3: letsSetUp
                case 4: keyboardSetup
                case 5: magic
                case 6: streakView
                case 7: styleView
                default: ready
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .animation(.spring(duration: 0.4), value: step)
        .foregroundStyle(Theme.ink).frame(maxWidth: 760).frame(maxWidth: .infinity) // iPad: conteúdo ao centro, fundo à largura toda
        .background((step == 0 ? Theme.ink : Color.white).ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: step)
    }

    private func next() { withAnimation { step += 1 } }

    // Intro do Flow: 3 slides que avançam sozinhos (~2,4 s) com crossfade, dots e CTA creme.
    @State private var slide = 0
    private let slides: [(String, String)] = [("A Fala é um teclado que ", "ouve"), ("4x mais rápido ", "do que escrever"), ("Funciona em ", "todas as apps")]
    private var intro: some View {
        VStack(spacing: 0) {
            FalaLogo().scaleEffect(1.1).padding(.top, 26)
            Spacer()
            ZStack {
                Circle().fill(Theme.purple.opacity(0.25)).frame(width: 300).blur(radius: 60)
                    .offset(x: CGFloat(slide - 1) * 60)
                WavePill(level: [0.5, 0.9, 0.7][slide], active: true).scaleEffect(1.9)
            }
            Spacer()
            ZStack {
                ForEach(slides.indices, id: \.self) { i in
                    if i == slide {
                        (Text(slides[i].0).font(Theme.garamond(38)) + Text(slides[i].1).font(Theme.garamond(38, italic: true)))
                            .multilineTextAlignment(.center).padding(.horizontal, 30).minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
            }.frame(height: 130)
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { i in Capsule().fill(.white.opacity(i == slide ? 1 : 0.35)).frame(width: i == slide ? 18 : 7, height: 7) }
            }.padding(.vertical, 22)
            Button { tick(); next() } label: {
                Text("Começar").font(Theme.sans(17, .semibold)).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity).frame(height: 54).background(Theme.cream, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }.buttonStyle(PressScale()).padding(.horizontal, 20).padding(.bottom, 16)
        }
        .foregroundStyle(.white).frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.5), value: slide)
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(2.4)); slide = (slide + 1) % 3 } }
    }

    private var quizView: some View {
        VStack(spacing: 14) {
            Text("Com qual destas te identificas?").font(Theme.garamond(30)).multilineTextAlignment(.center).padding(.top, 24)
            Text("Escolhe todas as que se aplicam.").font(Theme.sans(15))
            ForEach(quiz.indices, id: \.self) { i in
                Button { tick(); if picks.contains(i) { picks.remove(i) } else { picks.insert(i) } } label: {
                    HStack(spacing: 12) { Image(systemName: quiz[i].0).frame(width: 22); Text(quiz[i].1).font(Theme.sans(15)); Spacer() }
                        .padding(16).background(picks.contains(i) ? Theme.cream : .white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(picks.contains(i) ? Theme.ink : Color.black.opacity(0.15), lineWidth: picks.contains(i) ? 2 : 1))
                }.buttonStyle(.plain).sensoryFeedback(.selection, trigger: picks.contains(i))
            }
            Spacer()
            Button("Seguinte") { tick(); next() }.buttonStyle(DarkButton(enabled: !picks.isEmpty)).disabled(picks.isEmpty)
        }.padding(20)
    }

    // Resposta personalizada à 1.ª escolha do quiz (como "Perfect, Flow is great for sending messages").
    private var personalized: some View {
        let first = picks.min() ?? 0
        let (word, icon, tint): (String, String, Color) = [
            ("mensagens", "message.fill", Color(red: 0.86, green: 0.28, blue: 0.25)), ("emails", "envelope.fill", Color(red: 0.17, green: 0.45, blue: 0.85)),
            ("falar com IA", "sparkles", Theme.purple), ("apontar ideias", "lightbulb.fill", Theme.orange),
            ("o teu Mac", "laptopcomputer", Theme.forest), ("escrever no telemóvel", "keyboard.fill", Theme.forest)][min(first, 5)]
        return VStack(spacing: 22) {
            (Text("Perfeito, a Fala é ótima para ").font(Theme.garamond(32)) + Text(word).font(Theme.garamond(32, italic: true)))
                .multilineTextAlignment(.center).padding(.top, 24).padding(.horizontal, 24)
            Spacer()
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.gradient)
                .overlay(alignment: .topLeading) {
                    Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.white).frame(width: 64, height: 64)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 15, style: .continuous)).padding(14)
                }
                .overlay { WavePill(level: 0.7, active: true).scaleEffect(1.6).phaseAnimator([0.9, 1.05]) { v, p in v.scaleEffect(p) } animation: { _ in .easeInOut(duration: 0.8) } }
                .frame(width: 290, height: 290)
            Spacer()
            Button("Seguinte") { tick(); next() }.buttonStyle(DarkButton()).padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    private var letsSetUp: some View {
        VStack(spacing: 18) {
            Spacer()
            (Text("Vamos ").font(Theme.garamond(56)) + Text("configurar").font(Theme.garamond(56)).foregroundColor(Theme.orange) + Text(" a Fala").font(Theme.garamond(56)))
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Text("Só demora um momento").font(Theme.sans(17))
            Spacer()
            Button { tick(); next() } label: {
                Text("Configurar").font(Theme.sans(17, .semibold)).foregroundStyle(Theme.ink).frame(maxWidth: .infinity).frame(height: 54)
                    .background(Theme.lilac, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.ink, lineWidth: 1.5))
            }.buttonStyle(PressScale()).padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    // Passos do teclado com toggles falsos animados (o Flow faz o mesmo antes de abrir as Definições).
    @State private var fakeOn = false
    private var keyboardSetup: some View {
        VStack(spacing: 20) {
            Text("Ativa o teclado Fala nas Definições").font(Theme.garamond(32)).multilineTextAlignment(.center).padding(.top, 24).padding(.horizontal, 24)
            VStack(spacing: 0) {
                row("keyboard", "Teclados", nil)
                Divider().padding(.leading, 52)
                row("waveform", "Fala", $fakeOn)
                Divider().padding(.leading, 52)
                row("lock.open", "Permitir acesso total", $fakeOn)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
            .padding(.horizontal, 24)
            (Text("Os teus dados estão ").font(Theme.sans(15)) + Text("seguros").font(Theme.sans(15)).italic() + Text(". O acesso total serve só para o teclado receber o texto que ditas na Fala.").font(Theme.sans(15)))
                .foregroundStyle(.white).padding(14).background(Theme.primary, in: RoundedRectangle(cornerRadius: 12)).padding(.horizontal, 24)
            Spacer()
            Button("Abrir Definições") { tick(); if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }; next() }
                .buttonStyle(DarkButton()).padding(.horizontal, 20)
            Button("Faço depois") { tick(); next() }.font(Theme.sans(15)).foregroundStyle(Theme.muted).padding(.bottom, 12)
        }
        .task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(1.2)); withAnimation(.spring(duration: 0.4)) { fakeOn.toggle() } } }
    }
    private func row(_ icon: String, _ title: String, _ on: Binding<Bool>?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.white).frame(width: 28, height: 28).background(Color.gray, in: RoundedRectangle(cornerRadius: 7))
            Text(LocalizedStringKey(title)).font(Theme.sans(16))
            Spacer()
            if let on { Toggle("", isOn: on).labelsHidden().tint(Theme.green).allowsHitTesting(false) } else { Image(systemName: "chevron.right").foregroundStyle(Theme.muted) }
        }.padding(.horizontal, 12).frame(height: 52)
    }

    @State private var magicPhase: FlowRecorderPanel.Phase = .idle
    private var magic: some View {
        VStack(spacing: 18) {
            (Text("Diz qualquer coisa, toca em ").font(Theme.garamond(30)) + Text(Image(systemName: "checkmark.circle.fill")).font(Theme.garamond(30)) + Text(" e vê aparecer como magia ✨").font(Theme.garamond(30)))
                .multilineTextAlignment(.center).padding(.top, 24).padding(.horizontal, 20)
            Text(mic.isRecording ? (mic.text.isEmpty ? "Diz alguma coisa!" : mic.text) : (tried.isEmpty ? "Diz alguma coisa!" : tried))
                .font(Theme.sans(17)).foregroundStyle(tried.isEmpty && (mic.text.isEmpty || !mic.isRecording) ? Theme.ink.opacity(0.35) : Theme.ink)
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading).padding(16)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line)).padding(.horizontal, 20)
                .animation(.easeOut(duration: 0.15), value: mic.text)
            if let e = mic.error { Text(e).font(Theme.sans(12)).foregroundStyle(.red) }
            if !tried.isEmpty { Button("Seguinte") { tick(); next() }.buttonStyle(DarkButton()).padding(.horizontal, 20).transition(.move(edge: .bottom).combined(with: .opacity)) }
            Spacer()
            FlowRecorderPanel(phase: magicPhase, level: mic.level, bottomInset: 30, start: {
                Task { _ = await mic.authorize(); mic.start(); if mic.isRecording { magicPhase = .listening } }
            }, cancel: { Task { _ = await mic.stop(); magicPhase = .idle } }, finish: {
                Task {
                    magicPhase = .processing
                    let t = store.process(await mic.stop())
                    if !t.isEmpty { tried = t; store.add(t, seconds: mic.seconds); magicPhase = .done("Parabéns 🎉") } else { magicPhase = .idle }
                }
            })
        }
        .ignoresSafeArea(edges: .bottom)
        .animation(.spring(duration: 0.4), value: tried)
    }

    private var streakView: some View {
        VStack(alignment: .leading, spacing: 26) {
            (Text("Parabéns! Já sentiste a ").font(Theme.garamond(36)) + Text("magia da Fala ✨").font(Theme.garamond(36, italic: true))).padding(.top, 40)
            VStack(spacing: 14) {
                Text("1 dia seguido 🔥").font(Theme.garamond(26))
                Text("Usa a Fala nos próximos 5 dias e ela aprende contigo.").font(Theme.sans(15)).multilineTextAlignment(.center)
                HStack(spacing: 18) {
                    ForEach(1...5, id: \.self) { d in
                        VStack(spacing: 6) {
                            Image(systemName: "checkmark").font(Theme.sans(12, .bold)).foregroundStyle(.white)
                                .frame(width: 26, height: 26).background(d == 1 ? Theme.orange : Theme.line, in: Circle())
                            Text("Dia \(d)").font(Theme.sans(11))
                        }
                    }
                }
            }.padding(22).frame(maxWidth: .infinity).overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
            Spacer()
            Button("Continuar") { tick(); next() }.buttonStyle(DarkButton())
        }.padding(20).sensoryFeedback(.success, trigger: step)
    }

    private var styleView: some View {
        VStack(spacing: 14) {
            (Text("Escolhe o teu ").font(Theme.garamond(32)) + Text("estilo").font(Theme.garamond(32)).foregroundColor(Theme.purple)).padding(.top, 20)
            Text("A Fala usa este estilo em todos os ditados. Podes mudar quando quiseres.").font(Theme.sans(15)).multilineTextAlignment(.center).padding(.horizontal, 10)
            ForEach(Store.styles, id: \.0) { s in
                let on = store.style == s.0
                Button { tick(); store.style = s.0 } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.0).font(Theme.sans(17, .semibold)); Text(s.1).font(Theme.sans(15))
                        if on {
                            // Bolha de mensagem com avatar, como o preview do Flow.
                            HStack(alignment: .top, spacing: 8) {
                                Text("J").font(Theme.sans(12, .semibold)).foregroundStyle(.white).frame(width: 24, height: 24).background(Color(red: 0.93, green: 0.55, blue: 0.75), in: Circle())
                                Text(s.2).font(Theme.sans(15)).padding(.horizontal, 12).padding(.vertical, 9)
                                    .background(Color(red: 0.95, green: 0.94, blue: 0.97), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .padding(.top, 10).transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    .background(on ? Theme.cream : .white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Theme.ink : Color.black.opacity(0.15), lineWidth: on ? 1.5 : 1))
                }.buttonStyle(.plain)
            }
            Spacer()
            Button("Seguinte") { tick(); next() }.buttonStyle(DarkButton())
        }.padding(20).animation(.spring(duration: 0.35, bounce: 0.2), value: store.style)
        .sensoryFeedback(.selection, trigger: store.style)
    }

    private var ready: some View {
        VStack(spacing: 20) {
            Spacer()
            (Text("Está ").font(Theme.garamond(46)) + Text("pronto!").font(Theme.garamond(46, italic: true)).foregroundColor(Theme.orange))
            Text("Abre a Fala no Mac. Depois, na aba Mac, falas aqui e o texto aparece lá.").multilineTextAlignment(.center).foregroundStyle(Theme.muted).padding(.horizontal, 20)
            Spacer()
            Button("Entrar") { tick(); done() }.buttonStyle(DarkButton())
        }.padding(20).sensoryFeedback(.success, trigger: step)
    }
}
