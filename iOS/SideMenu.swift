import SwiftUI

/// Menu lateral do Flow (61): avatar, nome, progresso, botão lilás, lista de ações. Desliza da esquerda
/// com mola, o fundo escurece; arrastar para a esquerda ou tocar fora fecha.
struct SideMenu: View {
    @Binding var open: Bool
    @EnvironmentObject var store: Store
    @EnvironmentObject var mac: MacSender
    @EnvironmentObject var mic: Transcriber
    @AppStorage("onboarded.v2") private var onboarded = true
    @State private var drag: CGFloat = 0
    @State private var stats = false
    @State private var pairing = false
    @State private var remoteKeys = false
    @State private var remoteScreen = false
    @State private var pcScreen = false
    @State private var keyboardSetup = false
    @State private var confirmDelete = false
    @State private var aiAccounts = false
    @State private var settings = false
    @ObservedObject private var account = FalaAccount.shared
    @AppStorage("fala.loginSkipped") private var loginSkipped = false
    @AppStorage("fala.pcCode") private var pcCode = ""

    var body: some View {
        GeometryReader { g in
            let w = min(300, g.size.width * 0.74)
            ZStack(alignment: .leading) {
                Color.black.opacity(open ? 0.32 * (1 - Double(-drag / w)) : 0).ignoresSafeArea()
                    .allowsHitTesting(open)
                    .onTapGesture { close() }
                VStack(alignment: .leading, spacing: 0) {
                    Text("F").font(Theme.sans(22, .bold)).foregroundStyle(.white)
                        .frame(width: 52, height: 52).background(Theme.ink, in: Circle())
                    HStack(spacing: 8) {
                        Text("Fala").font(Theme.sans(22, .semibold))
                        Text(mac.macName == nil ? "Sem Mac" : "Mac ligado").font(Theme.sans(12, .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(mac.macName == nil ? Theme.disabled : Theme.purple, in: RoundedRectangle(cornerRadius: 5))
                    }.padding(.top, 14)
                    Text("\(store.totalWords.formatted()) palavras · \(store.wpm) WPM").font(Theme.sans(15)).foregroundStyle(Theme.ink.opacity(0.7)).padding(.top, 4)
                    Text("\(min(store.streak, 5)) de 5 dias seguidos").font(Theme.sans(14)).foregroundStyle(Theme.ink.opacity(0.7)).padding(.top, 22)
                    GeometryReader { b in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.1))
                            Capsule().fill(Theme.purple).frame(width: b.size.width * CGFloat(min(store.streak, 5)) / 5)
                        }
                    }.frame(height: 4).padding(.top, 8)
                    Button { tick(); stats = true } label: {
                        Text("Ver estatísticas").font(Theme.sans(16, .medium)).foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14).frame(height: 40).background(Theme.lilac, in: RoundedRectangle(cornerRadius: 10))
                    }.padding(.top, 18)
                    Spacer()
                    // ponytail: só o essencial; ditar, controlar o Mac/PC e o teclado remoto vivem nas abas.
                    section("Ligações")
                    item("laptopcomputer", mac.paired ? mac.label : "Ligar ao Mac (QR)") { pairing = true }
                    item("pc", pcCode.isEmpty ? "Ligar ao PC (QR)" : (UserDefaults.standard.string(forKey: "fala.pcName") ?? "PC") + " ligado") { pairing = true }
                    if MacSender.paired || !pcCode.isEmpty { item("sparkles", "Contas de IA") { aiAccounts = true } }
                    section("App")
                    item("gearshape", "Definições") { settings = true }
                    item("keyboard", "Teclado da Fala") { keyboardSetup = true }
                    item("questionmark.circle", "Rever o tutorial") { close(); onboarded = false }
                    item("hand.raised", "Privacidade") { close(); if let u = URL(string: LinkCrypto.relayBase + "/privacidade") { UIApplication.shared.open(u) } }
                    Divider().padding(.vertical, 6)
                    if account.signedIn {
                        item("person.crop.circle.badge.checkmark", "Terminar sessão") { Task { await account.signOut() } }
                        item("trash", "Apagar conta") { confirmDelete = true }
                    } else {
                        item("apple.logo", "Entrar com a Apple") { close(); loginSkipped = false }
                    }
                }
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 30)
                .frame(width: w, alignment: .leading).frame(maxHeight: .infinity)
                .background(Color.white.ignoresSafeArea())
                .offset(x: open ? min(0, drag) : -w - 30)
                .gesture(DragGesture().onChanged { drag = min(0, $0.translation.width) }.onEnded { v in
                    if v.predictedEndTranslation.width < -w / 3 { close() } else { withAnimation(.spring(duration: 0.3)) { drag = 0 } }
                })
            }
        }
        .foregroundStyle(Theme.ink)
        .sheet(isPresented: $stats) { StatsSheet().presentationDetents([.medium]).presentationCornerRadius(28) }
        .sheet(isPresented: $pairing) { MacPairingView().environmentObject(mac) }
        .sheet(isPresented: $remoteKeys) { RemoteKeyboardView().environmentObject(mac).environmentObject(mic).environmentObject(store) }
        .sheet(isPresented: $keyboardSetup) { KeyboardSetupView() }
        .sheet(isPresented: $settings) { MascotSettingsView() }
        .fullScreenCover(isPresented: $remoteScreen) { RemoteScreenView().environmentObject(mac).environmentObject(mic).environmentObject(store) }
        .fullScreenCover(isPresented: $pcScreen) { RemoteScreenView(pc: true).environmentObject(mac).environmentObject(mic).environmentObject(store) }
        .sensoryFeedback(.impact(weight: .light), trigger: open)
        .onAppear {
            switch Demo.open { case "remoto": remoteScreen = true; case "contas": aiAccounts = true; case "teclado": remoteKeys = true; default: break }
        }
        .sheet(isPresented: $aiAccounts) { AIAccountsView().environmentObject(mac).environmentObject(mic).environmentObject(store) }
        .confirmationDialog("Apagar a conta e os computadores guardados nela?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Apagar conta", role: .destructive) { tick(); Task { if await account.deleteAccount() { close() } } }
        } message: { Text("Os computadores continuam ligados neste iPhone. Podes voltar a entrar quando quiseres.") }
    }

    private func close() { withAnimation(.spring(duration: 0.35, bounce: 0.05)) { open = false; drag = 0 } }

    private func section(_ t: String) -> some View {
        Text(t.uppercased()).font(Theme.sans(12, .semibold)).foregroundStyle(Theme.muted).padding(.top, 14).padding(.bottom, 2)
    }

    private func item(_ icon: String, _ title: String, ext: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: { tick(); action() }) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 22)
                Text(LocalizedStringKey(title)).font(Theme.sans(17)).lineLimit(1)
                Spacer()
                if ext { Image(systemName: "arrow.up.right").font(.system(size: 13)) }
            }.frame(height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct MascotSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Mascote").font(Theme.sans(22, .semibold))
                    MascotPicker()
                }.padding(20)
            }
            .background(Theme.appBG).navigationTitle("Definições").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Concluído") { dismiss() } } }
        }
    }
}
