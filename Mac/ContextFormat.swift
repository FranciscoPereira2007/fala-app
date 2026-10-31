import AppKit
import ApplicationServices

/// Ditado consciente do sítio onde estás (como o Wispr Flow): a app à frente e o título da janela dizem se é um e-mail.
/// Num e-mail o texto sai estruturado: saudação numa linha, parágrafos, despedida e assinatura em linhas próprias.
/// Regras locais (instantâneo, grátis); o conteúdo nunca muda, só a forma.
enum ContextFormat {
    enum Kind { case email, plain }

    static let mailApps: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron", "com.mimestream.Mimestream", "it.bloop.airmail2", "com.google.Gmail"]
    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.brave.Browser", "org.mozilla.firefox", "com.microsoft.edgemac"]

    static func current() -> Kind {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return .plain }
        if mailApps.contains(id) { return .email }
        if browsers.contains(id), let t = windowTitle(app.processIdentifier)?.lowercased(),
           ["gmail", "outlook", "mail", "correio", "nova mensagem", "new message", "compose", "escrever"].contains(where: t.contains) { return .email }
        return .plain
    }

    private static func windowTitle(_ pid: pid_t) -> String? {
        let a = AXUIElementCreateApplication(pid)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(a, kAXFocusedWindowAttribute as CFString, &w) == .success, let w else { return nil }
        var t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success else { return nil }
        return t as? String
    }

    static func apply(_ text: String) -> String { current() == .email ? email(text) : text }

    static let greetings = ["olá", "ola", "bom dia", "boa tarde", "boa noite", "caro", "cara", "caros", "caras", "exmo", "exma", "prezado", "prezada", "querido", "querida", "oi", "hi", "hello", "dear"]
    static let closings = ["cumprimentos", "melhores cumprimentos", "com os melhores cumprimentos", "atenciosamente", "obrigado", "obrigada", "muito obrigado", "muito obrigada",
                           "um abraço", "abraço", "beijinhos", "beijos", "até breve", "até já", "best regards", "kind regards", "regards", "thanks", "thank you", "cheers"]

    /// "olá joão tudo bem queria saber se... obrigado francisco" -> "Olá João,\n\nTudo bem? ...\n\nObrigado,\nFrancisco"
    static func email(_ raw: String) -> String {
        var s = SpokenSentences.split(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !s.isEmpty else { return raw }
        var head: String?, tail: [String] = []
        // Saudação: a 1.ª frase começa por "Olá"/"Bom dia"/...; se for longa, corta no nome ("Olá João, queria..." -> "Olá João,").
        if let f = s.first {
            let lf = f.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!,"))
            if let g = greetings.first(where: { lf.hasPrefix($0 + " ") || lf.hasPrefix($0 + ",") || lf == $0 }) {
                if let c = f.firstIndex(of: ",") { // "Olá João, tudo bem?" -> "Olá João," + "Tudo bem?"
                    head = String(f[..<c]); let rest = String(f[f.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty { s.removeFirst() } else { s[0] = cap(rest) }
                } else if lf.split(separator: " ").count <= g.split(separator: " ").count + 2 { // "Bom dia." / "Olá João."
                    head = f.trimmingCharacters(in: CharacterSet(charactersIn: ".!")); s.removeFirst()
                }
            }
        }
        // Despedida: uma das últimas frases é "Obrigado"/"Cumprimentos"; o que vem depois (curto) é a assinatura.
        if let i = s.indices.reversed().first(where: { i in closings.contains { s[i].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!, ")).hasPrefix($0) } }), s.count - i <= 2 {
            let c = s[i].trimmingCharacters(in: CharacterSet(charactersIn: ".!, "))
            let k = closings.filter { c.lowercased().hasPrefix($0) }.max { $0.count < $1.count }!
            let after = c.dropFirst(k.count).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            let sign = (after.isEmpty ? [] : [cap(after)]) + s[(i + 1)...].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            tail = [String(c.prefix(k.count)) + (sign.isEmpty ? "." : ",")] + sign
            s = Array(s[..<i])
        }
        // Corpo: parágrafos de 2 frases (ou 1 se for longa), como se escreve um e-mail.
        var paras: [String] = [], cur: [String] = []
        for x in s {
            cur.append(x)
            if cur.count == 2 || x.split(separator: " ").count > 25 { paras.append(cur.joined(separator: " ")); cur = [] }
        }
        if !cur.isEmpty { paras.append(cur.joined(separator: " ")) }
        var out: [String] = []
        if let head { out.append(cap(head) + ",") }
        out += paras
        var body = out.joined(separator: "\n\n")
        if !tail.isEmpty { body += "\n\n" + tail.joined(separator: "\n") }
        return body
    }

    private static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

/// Frases por pontuação final (. ! ?), sem partir abreviaturas comuns.
enum SpokenSentences {
    static func split(_ t: String) -> [String] {
        var out: [String] = [], cur = ""
        let words = t.split(separator: " ", omittingEmptySubsequences: true)
        for w in words {
            cur += (cur.isEmpty ? "" : " ") + w
            if let l = w.last, ".!?".contains(l), !["sr.", "sra.", "dr.", "dra.", "eng.", "ex."].contains(w.lowercased()) { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
