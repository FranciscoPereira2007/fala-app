import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Frente de voz rápida: o modelo do Apple Intelligence (já vem no macOS, sem custo nem download da app) responde
/// logo como um colega ao telefone, enquanto a sessão lenta trabalha. Sem Apple Intelligence: frases fixas.
enum VoiceFront {
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { if case .available = SystemLanguageModel.default.availability { return true } }
        #endif
        return false
    }

    /// Frase curta a confirmar o pedido ("Ok, vou pôr o botão verde na loja."). nil = sem modelo ou demorou > 1,5 s.
    static func ack(_ said: String, session: String) async -> String? {
        await ask("""
        Estás ao telefone com o Fran. Ele pediu isto à sessão de programação "\(session)": "\(said)".
        Confirma numa frase curta (máx. 12 palavras) que percebeste e que a sessão vai tratar. Não inventes resultados.
        """, timeout: 1.5)
    }

    /// Resposta longa do agente -> 2 a 3 frases faladas, naturais, sem código nem caminhos. nil = usa o resumo por regras.
    static func spoken(_ reply: String, session: String) async -> String? {
        await ask("""
        A sessão "\(session)" respondeu isto ao Fran:
        \(reply.prefix(4000))
        Diz-lho ao telefone em 2 ou 3 frases curtas: o resultado e o próximo passo. Sem listas, sem código, sem caminhos de ficheiros, sem URLs.
        """, timeout: 4)
    }

    private static func ask(_ prompt: String, timeout: Double) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), available else { return nil }
        return await withTaskGroup(of: String?.self) { g in
            g.addTask {
                let s = LanguageModelSession(instructions: "És o Jarvis, assistente do Fran. Falas português de Portugal (nunca do Brasil), direto e caloroso, como um engenheiro colega ao telefone. Nunca uses travessões.")
                return try? await s.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            g.addTask { try? await Task.sleep(for: .seconds(timeout)); return nil }
            let r = await g.next() ?? nil
            g.cancelAll()
            return r?.isEmpty == false ? r : nil
        }
        #else
        return nil
        #endif
    }
}

/// Ruído que o Whisper transforma em "palavras" (eco da própria voz, barulho da rua): não vai para a sessão.
enum NoiseGuard {
    static let short: Set<String> = ["sim", "não", "nao", "ok", "okay", "certo", "boa", "para", "pára", "espera", "continua", "repete", "desliga", "obrigado", "obrigada", "isso", "exato", "manda", "envia", "cancela", "adeus"]
    /// Frases que o Whisper inventa em silêncio.
    static let ghosts = ["legendas pela comunidade", "amara.org", "inscreva-se", "obrigado por assistir", "sous-titres", "subtitles by", "thank you for watching"]
    /// Palavras portuguesas muito comuns: uma frase curta sem nenhuma destas é quase sempre ruído ("Ejra, Zyra, P").
    static let common: Set<String> = ["o", "a", "os", "as", "um", "uma", "de", "do", "da", "dos", "das", "em", "no", "na", "e", "é", "que", "com", "por", "para", "se", "me", "te", "eu", "tu", "ele", "ela", "isto", "isso", "aquilo", "ai", "aí", "aqui", "lá", "já", "mais", "muda", "mudar", "faz", "fazer", "vê", "ver", "mostra", "abre", "fecha", "põe", "tira", "diz", "quero", "queres", "está", "estás", "tem", "tens", "como", "onde", "quando", "porque", "qual", "quanto", "agora", "depois", "também", "bem", "olha", "então", "ok", "sim", "não", "botão", "ecrã", "site", "app", "sessão", "código", "testa", "corre", "mete", "cor", "vai", "vou", "foi", "ficou", "manda", "envia", "lê", "pára", "espera", "continua"]

    /// A mesma palavra 4+ vezes seguidas (alucinação típica).
    static func looped(_ t: String) -> Bool { t.range(of: #"(\b[\p{L}-]+\b)(?:[\s,.]+\1\b){3,}"#, options: .regularExpression) != nil }

    static func isNoise(_ text: String, seconds: Double) -> Bool {
        let low = text.lowercased()
        if ghosts.contains(where: low.contains) { return true }
        if looped(low) { return true }
        let words = low.split { !$0.isLetter && $0 != "-" }.map(String.init).filter { !$0.isEmpty }
        if words.isEmpty { return true }
        if words.count <= 2, words.allSatisfy(short.contains) { return false }
        if words.count <= 4, !words.contains(where: common.contains), !words.contains(where: short.contains) { return true }
        return seconds < 0.5 && words.count > 3 // 4+ palavras em meio segundo não é fala
    }
}

