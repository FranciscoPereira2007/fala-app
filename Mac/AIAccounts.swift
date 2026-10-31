import Foundation
import AppKit

/// Quem usa este Mac (o nome da conta do macOS): a Fala trata cada pessoa pelo nome dela.
enum Me { static var firstName: String { NSFullUserName().split(separator: " ").first.map(String.init) ?? "" } }

/// Contas de IA deste Mac: Claude (Claude Code) e ChatGPT (Codex), cujas sessões aparecem no iPhone.
/// O login é sempre da própria pessoa, no browser (a Fala só abre o Terminal com o comando oficial).
enum AIAccounts {
    static let kinds = ["claude", "codex"]
    private static let paths = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.npm-global/bin", NSHomeDirectory() + "/.bun/bin"]

    /// Sítios habituais; senão pergunta à shell da pessoa (nvm, ~/bin, etc.), como o Terminal dela o encontraria.
    static func which(_ n: String) -> String? {
        if let p = paths.map({ $0 + "/" + n }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        let (_, out) = run("/bin/zsh", ["-lic", "command -v \(n)"])
        return out.split(separator: "\n").map(String.init).last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        var env = ProcessInfo.processInfo.environment; env["PATH"] = (paths + [env["PATH"] ?? ""]).joined(separator: ":"); p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        guard (try? p.run()) != nil else { return (-1, "") }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return (-1, "") }
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// Estado das duas contas (corre os CLIs; chamar fora do main thread).
    static func status() -> [String: Jarvis.AIAccount] {
        var out: [String: Jarvis.AIAccount] = [:]
        if let c = which("claude") {
            let (_, s) = run(c, ["auth", "status", "--json"])
            let j = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
            out["claude"] = .init(installed: true, loggedIn: j?["loggedIn"] as? Bool ?? false)
        } else { out["claude"] = .init(installed: false, loggedIn: false) }
        if let x = which("codex") {
            let (code, s) = run(x, ["login", "status"])
            out["codex"] = .init(installed: true, loggedIn: code == 0 && s.lowercased().contains("logged in"))
        } else { out["codex"] = .init(installed: false, loggedIn: false) }
        return out
    }

    /// Abre o Terminal com o login (ou a instalação oficial e depois o login). O browser abre sozinho.
    static func login(_ kind: String) {
        let cmd: String
        switch (kind, which(kind) != nil) {
        case ("claude", true): cmd = "claude auth login"
        case ("claude", false): cmd = "curl -fsSL https://claude.ai/install.sh | bash && ~/.local/bin/claude auth login"
        case ("codex", true): cmd = "codex login"
        case ("codex", false): cmd = "(command -v brew >/dev/null && brew install codex || npm install -g @openai/codex) && codex login"
        default: return
        }
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("Fala-\(kind)-login.command")
        let script = "#!/bin/zsh -l\nexport PATH=\"\(paths.joined(separator: ":")):$PATH\"\necho 'Fala: a ligar a tua conta (\(kind == "claude" ? "Claude" : "ChatGPT")). Acaba o login no browser.'\n\(cmd)\n"
        try? script.write(to: f, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        DispatchQueue.main.async { NSWorkspace.shared.open(f) }
    }
}
