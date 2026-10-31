import SwiftUI
import AuthenticationServices
import CryptoKit

/// Conta da Fala: "Entrar com a Apple" e os computadores da pessoa (Mac/PC) guardados na conta (relay /a/...).
/// Um iPhone novo com a mesma conta recebe logo os computadores; ligar um computador (QR) junta-o à conta.
@MainActor final class FalaAccount: ObservableObject {
    static let shared = FalaAccount()
    @Published private(set) var session = UserDefaults.standard.string(forKey: "fala.session") ?? ""
    @Published var error: String?
    var signedIn: Bool { !session.isEmpty }

    struct Device: Codable { var id = "", kind = "mac", name = "", code = "", lan = "" }
    private struct Reply: Codable { var session: String?; var devices: [Device]?; var error: String? }

    func signIn(_ r: Result<ASAuthorization, Error>) async {
        guard case .success(let a) = r, let c = a.credential as? ASAuthorizationAppleIDCredential,
              let t = c.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
            if case .failure(let e) = r, (e as? ASAuthorizationError)?.code != .canceled { error = "Não deu para entrar com a Apple" }
            return
        }
        guard let rep = await call("POST", "/a/login", ["token": t]), let s = rep.session else { error = error ?? "Sem ligação. Tenta outra vez."; return }
        setSession(s)
        apply(rep.devices ?? [])
        await push()
    }

    /// Computadores da conta preenchem o que este iPhone ainda não tem (o que já está ligado aqui manda).
    private func apply(_ ds: [Device]) {
        if !MacSender.paired, let m = ds.last(where: { $0.kind == "mac" }) { MacSender.token = m.code; MacSender.host = m.lan }
        if PCNode.code.isEmpty, let p = ds.last(where: { $0.kind == "pc" }) { Pairing.setPC(code: p.code, lan: p.lan, name: p.name) }
    }

    /// Guarda na conta os computadores ligados neste iPhone.
    func push() async {
        guard signedIn else { return }
        if MacSender.paired {
            _ = await call("POST", "/a/device", ["id": Self.id(MacSender.token), "kind": "mac", "name": UserDefaults.standard.string(forKey: "fala.macName") ?? "Mac",
                                                 "code": MacSender.token, "lan": MacSender.host])
        }
        if !PCNode.code.isEmpty {
            _ = await call("POST", "/a/device", ["id": Self.id(PCNode.code), "kind": "pc", "name": UserDefaults.standard.string(forKey: "fala.pcName") ?? "PC",
                                                 "code": PCNode.code, "lan": UserDefaults.standard.string(forKey: "fala.pcNode") ?? ""])
        }
    }

    func signOut() async { _ = await call("POST", "/a/logout", [:]); setSession("") }
    func deleteAccount() async -> Bool {
        guard await call("DELETE", "/a/account", nil) != nil else { error = "Não deu para apagar. Tenta outra vez."; return false }
        setSession(""); return true
    }

    static func id(_ code: String) -> String { SHA256.hash(data: Data(("fala-device:" + code.uppercased()).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() }

    private func setSession(_ s: String) { session = s; UserDefaults.standard.set(s, forKey: "fala.session") }

    private func call(_ method: String, _ path: String, _ body: [String: String]?) async -> Reply? {
        guard let u = URL(string: LinkCrypto.relayBase + path) else { return nil }
        var r = URLRequest(url: u, timeoutInterval: 15); r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !session.isEmpty { r.setValue("Bearer " + session, forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        guard let (d, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse else { return nil }
        let rep = try? JSONDecoder().decode(Reply.self, from: d)
        if h.statusCode == 401, !session.isEmpty, path != "/a/login" { setSession("") } // sessão terminada noutro lado
        guard h.statusCode == 200 else { error = rep?.error; return nil }
        return rep ?? Reply()
    }
}

/// QR "fala://pair": Mac (t = código, h = endereço) ou PC (k=pc, t, h = IP:porta de casa, n = nome).
@MainActor enum Pairing {
    enum Kind { case mac, pc }
    @discardableResult static func apply(_ url: String) -> Kind? {
        guard let q = URLComponents(string: url)?.queryItems, let t = q.first(where: { $0.name == "t" })?.value, !t.isEmpty else { return nil }
        let v = { (n: String) in q.first(where: { $0.name == n })?.value ?? "" }
        if v("k") == "pc" { setPC(code: t, lan: v("h"), name: v("n")); return .pc }
        MacSender.token = t; if !v("h").isEmpty { MacSender.host = v("h") }
        return .mac
    }
    static func setPC(code: String, lan: String, name: String) {
        let d = UserDefaults.standard
        d.set(code.uppercased(), forKey: "fala.pcCode"); d.set(lan, forKey: "fala.pcNode"); d.set(name.isEmpty ? "PC" : name, forKey: "fala.pcName")
        PCNode.markDown(); PCNode.reset()
    }
}

/// 1.º ecrã: entrar com a Apple (os teus computadores ficam guardados na conta). "Agora não" deixa usar sem conta.
struct LoginView: View {
    @ObservedObject var account = FalaAccount.shared
    var skip: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 54, weight: .medium)).foregroundStyle(Theme.ink)
            (Text("A tua voz, ").font(Theme.garamond(34)) + Text("em todo o lado").font(Theme.garamond(34, italic: true)).foregroundColor(Theme.orange))
                .multilineTextAlignment(.center)
            Text("Entra para guardares o teu Mac e o teu PC na conta: controla-os de qualquer rede, em qualquer país.")
                .font(Theme.sans(16)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.horizontal, 28)
            Spacer()
            SignInWithAppleButton(.signIn) { $0.requestedScopes = [] } onCompletion: { r in Task { await account.signIn(r) } }
                .signInWithAppleButtonStyle(.black).frame(height: 52).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 24)
            if let e = account.error { Text(e).font(Theme.sans(14)).foregroundStyle(.red) }
            Button("Agora não", action: { tick(); skip() }).font(Theme.sans(15)).foregroundStyle(Theme.muted).padding(.bottom, 8)
            Text("Só guardamos um identificador anónimo da Apple e os teus computadores. Sem email, sem nome.")
                .font(Theme.sans(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).padding(.horizontal, 30).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity).background(Theme.appBG.ignoresSafeArea())
    }
}

/// Contas de IA nos computadores (Claude e ChatGPT/Codex): ver e entrar a partir do iPhone.
/// "Entrar" abre o login no browser do computador e o ecrã remoto para o acabares daqui, de qualquer rede.
struct AIAccountsView: View {
    @EnvironmentObject var mac: MacSender
    @EnvironmentObject var mic: Transcriber
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var macAcc: [String: Jarvis.AIAccount]?
    @State private var pcAcc: [String: Jarvis.AIAccount]?
    @State private var note: String?
    @State private var screen: Bool?   // true = PC, false = Mac
    @AppStorage("fala.pcCode") private var pcCode = ""

    var body: some View {
        NavigationStack {
            List {
                if MacSender.paired || Demo.on { section("Mac", macAcc, pc: false) }
                if !pcCode.isEmpty || Demo.on { section(UserDefaults.standard.string(forKey: "fala.pcName") ?? "PC", pcAcc, pc: true) }
                if !MacSender.paired && pcCode.isEmpty && !Demo.on { Text("Liga primeiro o teu Mac ou PC (menu, Ligar ao Mac/PC).").foregroundStyle(Theme.muted) }
                if let note { Section { Text(note).font(Theme.sans(14)).foregroundStyle(Theme.muted) } }
            }
            .navigationTitle("Contas de IA").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Feito") { tick(); dismiss() } } }
            .task { await load() }
            .refreshable { await load() }
            .fullScreenCover(item: Binding(get: { screen.map { Flag(pc: $0) } }, set: { screen = $0?.pc })) { f in
                RemoteScreenView(pc: f.pc).environmentObject(mac).environmentObject(mic).environmentObject(store)
            }
        }
    }
    private struct Flag: Identifiable { let pc: Bool; var id: Bool { pc } }

    private func section(_ title: String, _ acc: [String: Jarvis.AIAccount]?, pc: Bool) -> some View {
        Section(title) {
            ForEach(["claude", "codex"], id: \.self) { k in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(k == "claude" ? "Claude" : "ChatGPT").font(Theme.sans(16, .semibold))
                        Text(acc == nil ? "A ver…" : acc?[k]?.loggedIn == true ? "Ligado ✓" : acc?[k]?.installed == false ? "Não instalado" : "Não ligado")
                            .font(Theme.sans(13)).foregroundStyle(acc?[k]?.loggedIn == true ? Theme.forest : Theme.muted)
                    }
                    Spacer()
                    Button(acc?[k]?.loggedIn == true ? "Trocar" : acc?[k]?.installed == false ? "Instalar" : "Entrar") { tick(); Task { await login(k, pc: pc) } }
                        .buttonStyle(.borderedProminent).tint(Theme.ink).disabled(acc == nil)
                }
            }
        }
    }

    private func load() async {
        if Demo.on { macAcc = ["claude": .init(installed: true, loggedIn: true), "codex": .init(installed: true, loggedIn: true)]
                     pcAcc = ["claude": .init(installed: true, loggedIn: true), "codex": .init(installed: true, loggedIn: false)]; return }
        async let m: [String: Jarvis.AIAccount]? = MacSender.paired ? mac.jarvis(.init(op: "accounts"), timeout: 20)?.accounts : nil
        async let p: [String: Jarvis.AIAccount]? = pcCode.isEmpty ? nil : {
            guard let (s, _, d) = await PCNode.request("GET", "/accounts", timeout: 20), s == 200 else { return nil }
            return try? JSONDecoder().decode([String: Jarvis.AIAccount].self, from: d)
        }()
        (macAcc, pcAcc) = await (m, p)
        if macAcc == nil && pcAcc == nil { note = "O computador não respondeu. Tem a Fala aberta?" }
    }

    private func login(_ k: String, pc: Bool) async {
        let ok: Bool
        if pc {
            let body = try? JSONSerialization.data(withJSONObject: ["which": k])
            ok = await PCNode.request("POST", "/accounts/login", body: body, timeout: 15)?.0 == 200
        } else {
            ok = await mac.jarvis(.init(op: "login", id: k), timeout: 15)?.ok == true
        }
        note = ok ? "Abri o login no \(pc ? "PC" : "Mac"). Acaba-o no browser de lá: abro-te o ecrã." : "O \(pc ? "PC" : "Mac") não respondeu."
        if ok { try? await Task.sleep(for: .seconds(1.5)); screen = pc }
    }
}
