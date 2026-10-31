import SwiftUI

/// Aba "Controlar": o ecrã do teu Mac ou PC na mão, de qualquer rede (relay cifrado).
struct ControlView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var mac: MacSender
    @EnvironmentObject var mic: Transcriber
    @AppStorage("fala.pcCode") private var pcCode = ""
    @State private var screen: Bool?   // nil = fechado; false = Mac; true = PC
    @State private var pairing = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Controlar").font(Theme.garamond(34)).padding(.top, 8)
                Text("Vê o ecrã e mexe com o dedo, como num trackpad. Funciona em casa e do outro lado do mundo.")
                    .font(Theme.sans(15)).foregroundStyle(Theme.muted)
                card("laptopcomputer", "O teu Mac", mac.paired ? mac.label : nil) { if mac.paired { FalaOrientation.mask = .allButUpsideDown; screen = false } else { pairing = true } }
                card("pc", "O teu PC Windows", pcCode.isEmpty ? nil : UserDefaults.standard.string(forKey: "fala.pcName") ?? "PC ligado") { pcCode.isEmpty ? (pairing = true) : (screen = true) }
                Label("1 dedo mexe o rato, 2 dedos fazem scroll, 3 dedos mudam de app.", systemImage: "hand.tap")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted).padding(.top, 4)
            }.padding(20).padding(.bottom, 90)
        }
        .sheet(isPresented: $pairing) { MacPairingView().environmentObject(mac) }
        .fullScreenCover(isPresented: Binding(get: { screen != nil }, set: { if !$0 { screen = nil } })) {
            RemoteScreenView(pc: screen ?? false).environmentObject(mac).environmentObject(mic).environmentObject(store)
        }
    }
    private func card(_ icon: String, _ title: String, _ connected: String?, _ tap: @escaping () -> Void) -> some View {
        Button(action: { tick(); tap() }) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
                    .frame(width: 56, height: 56).background(Theme.lilac, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title)).font(Theme.sans(17, .semibold)).foregroundStyle(Theme.ink)
                    Text(connected ?? "Ligar com o código QR").font(Theme.sans(14)).foregroundStyle(connected == nil ? Theme.orange : Theme.muted)
                }
                Spacer()
                Text(connected == nil ? "Ligar" : "Abrir").font(Theme.sans(15, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 36).background(Theme.ink, in: Capsule())
            }
            .padding(16).background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }.buttonStyle(.plain)
    }
}

