import Foundation

/// Correção local de termos técnicos mal ouvidos ("pulo recosto" -> "pull request"), com um modelo grátis no Mac (Ollama, qwen2.5:3b).
/// Medido em research/stt-benchmark (ronda 5): misto 16,1% -> 8,5% de erro por palavra, pt-PT e inglês iguais.
/// Só corre quando a frase já tem termos técnicos (senão não atrasa o ditado) e só aceita mudanças que trazem termos técnicos conhecidos.
/// Sem Ollama a correr, devolve o texto como estava.
enum TechFix {
    static let tech: Set<String> = ["pull", "request", "merge", "rebase", "webhook", "stripe", "endpoint", "edge", "function", "functions",
        "landing", "page", "call", "to", "action", "hero", "deploy", "fix", "review", "onboarding", "supabase", "github", "commit", "push",
        "build", "testflight", "api", "frontend", "backend", "claude", "codex", "code", "prompt", "bug", "xcode"]
    static let prompt = """
        És um corretor de ditado em português de Portugal. O texto vem de reconhecimento de voz e pode ter termos técnicos ou palavras \
        inglesas mal ouvidas (ex.: 'pulo recosto' = 'pull request', 'e-book do strip' = 'webhook do Stripe', 'Coltoatium' = 'call to action'). \
        Corrige SÓ essas palavras mal ouvidas. Não mudes mais nada: nem pontuação, nem estilo, nem traduzas. Se estiver certo, devolve igual. \
        Responde só com o texto.

        Texto: 
        """

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).inverted).filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".-")) }.filter { !$0.isEmpty }
    }

    /// A correção do modelo só entra se as palavras novas forem todas termos técnicos e mudar no máximo 4 palavras.
    static func accept(_ before: String, _ after: String) -> Bool {
        let a = words(before), b = words(after)
        let new = Set(b).subtracting(a)
        guard !new.isEmpty, new.isSubset(of: tech) else { return false }
        return editDistance(a, b) <= 4
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        var d = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var p = d[0]; d[0] = i
            for j in 1...max(1, b.count) where !b.isEmpty { let t = d[j]; d[j] = min(d[j] + 1, d[j - 1] + 1, p + (a[i - 1] == b[j - 1] ? 0 : 1)); p = t }
        }
        return a.isEmpty ? b.count : d[b.count]
    }

    static func apply(_ text: String) async -> String {
        guard UserDefaults.standard.object(forKey: "fala.techFix") as? Bool ?? true, !Set(words(text)).isDisjoint(with: tech) else { return text }
        var r = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!, timeoutInterval: 3)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": "qwen2.5:3b", "prompt": prompt + text, "stream": false, "keep_alive": "30m",
                                                                 "options": ["temperature": 0, "num_predict": 160]])
        guard let (d, _) = try? await URLSession.shared.data(for: r),
              let out = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["response"] as? String else { return text }
        let fixed = out.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return accept(text, fixed) ? fixed : text
    }
}
