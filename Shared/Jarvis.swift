import Foundation
import CryptoKit

/// Jarvis: o iPhone vê e fala com as sessões Claude Code / Codex que correm no Mac.
///
/// Protocolo (dentro da cifra v2, ver LinkCrypto):
/// - "PJ" ping com capacidades. Mac novo responde "P" + nome + "\n" + "jarvis=1". Mac antigo responde só "P" + nome
///   (o iPhone sabe que não pode usar o Jarvis e nunca envia "J", que um Mac antigo colaria como texto).
/// - "J" + JSON(JarvisRequest) -> "J" + JSON(JarvisResponse). Pedido/resposta, uma ligação por mensagem.
/// - "C" + JSON(CallStart) abre uma chamada: o Mac responde "C" + nonce(16) e a ligação FICA aberta.
///   Daí em diante os dois lados trocam frames CallFrame cifrados com uma chave só desta chamada.
enum Jarvis {
    static let capability = "jarvis=1"

    struct Session: Codable, Identifiable, Hashable {
        enum Kind: String, Codable { case claude, codex }
        var id: String            // claude: sessionId; codex: thread id
        var kind: Kind
        var name: String
        var cwd: String
        var status: String        // "busy" | "idle" | outro (ex.: precisa de aprovação)
        var updatedAt: Date
        var pid: Int?
        var lastReply: String?    // última frase útil do agente (para a lista)
        var canSend: Bool         // claude: há separador iTerm; codex: sempre (codex queue)
        var mode: String? = nil   // claude: default | acceptEdits | plan | bypassPermissions (Shift+Tab no terminal)
        var tool: String? = nil   // ferramenta em curso, se é a última coisa da sessão ("Edit · Sessions.swift")
        var doing: String? { tool.map(Self.doing) } // numa frase: "A editar Sessions.swift"
        /// Ferramenta -> frase curta em PT ("Bash · git status" -> "A correr git status").
        static func doing(_ tool: String) -> String {
            let parts = tool.components(separatedBy: " · "), name = parts[0], arg = parts.dropFirst().joined(separator: " · ")
            if name == "Desc" { return String(arg.prefix(70)) } // o próprio agente descreveu o comando
            let verb: String = switch name {
            case "Bash", "exec_command", "shell", "PowerShell": "A correr"
            case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch": "A editar"
            case "Read": "A ler"
            case "Grep", "Glob": "A procurar"
            case "WebSearch", "WebFetch", "web_search": "A pesquisar"
            case "Agent", "Task": "A delegar"
            case "TodoWrite": "A planear"
            default: "A usar " + name
            }
            return arg.isEmpty || verb == "A planear" ? verb : verb + " " + String(arg.prefix(60))
        }
        var folder: String { (cwd as NSString).lastPathComponent }
        /// "shell", "running" e outros estados de trabalho contam como ocupada (a mensagem fica em fila).
        var busy: Bool { !["idle", "shell", "waiting", "permission", "needs_input", "approval", "requires_action"].contains(status) }
        /// Parada, mas com um comando em fundo (ex.: servidor) a correr.
        var shell: Bool { status == "shell" }
        /// Só pedidos de aprovação reais bloqueiam o envio (escrever ali responderia ao pedido).
        var needsYou: Bool { Self.needsYou(status) }
        /// Só estes estados pedem o Fran; qualquer outro que não seja "idle" (busy, shell, ...) é "a trabalhar".
        static func needsYou(_ status: String) -> Bool { ["waiting", "permission", "needs_input", "approval", "requires_action"].contains(status) }
    }

    struct Message: Codable, Identifiable, Hashable {
        var id: String
        var role: String          // "user" | "agent"
        var text: String
        var at: Date
    }

    struct Event: Codable, Identifiable, Hashable {
        enum Kind: String, Codable { case finished, needsYou }
        var id: Int
        var kind: Kind
        var sessionID: String
        var sessionName: String
        var summary: String
        var at: Date
    }

    struct Request: Codable {
        var op: String            // "list" | "tail" | "send" | "events"
        var id: String?
        var text: String?
        var limit: Int?
        var since: Int?
        var fileName: String? = nil   // anexo (foto/ficheiro): o Mac guarda em ~/Downloads/Fala e junta o caminho ao texto
        var file: Data? = nil
    }

    struct Response: Codable {
        var ok: Bool
        var error: String?
        var sessions: [Session]?
        var messages: [Message]?
        var events: [Event]?
        var lastEvent: Int?
        var commands: [String]? = nil
        var file: Data? = nil            // op "file": bytes de uma imagem/vídeo do Mac para o chat   // "/nome\tdescrição": skills, comandos e MCPs (lista do "/")
        var accounts: [String: AIAccount]? = nil // op "accounts": "claude" / "codex" deste computador
        var job: String? = nil      // op "dot": id do pedido ao teu Jarvis
        var reply: String? = nil    // op "dotResult": resposta (quando done)
        var done: Bool? = nil
        var progress: [String]? = nil // op "dotResult": o que o Jarvis já foi dizendo enquanto trabalha
    }

    /// Conta de IA no computador (Claude Code = "claude", ChatGPT/Codex = "codex").
    struct AIAccount: Codable, Equatable { var installed: Bool; var loggedIn: Bool }

    /// Caminhos de imagem/vídeo citados numa resposta do agente ("/Users/…/ecrã.png").
    static func mediaPaths(_ t: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "((?:/Users|/private|/tmp|/var)/[^\\s`'\"()<>]+?\\.(?:png|jpe?g|gif|webp|heic|mp4|mov))", options: .caseInsensitive)
        var seen: [String] = []
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            if let r = Range(m.range(at: 1), in: t), !seen.contains(String(t[r])) { seen.append(String(t[r])) }
        }
        return Array(seen.prefix(6))
    }
    static func isVideo(_ p: String) -> Bool { ["mp4", "mov"].contains((p as NSString).pathExtension.lowercased()) }

    struct CallStart: Codable { var session: String }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }()

    static func encode<T: Encodable>(_ prefix: String, _ v: T) -> Data { Data(prefix.utf8) + ((try? encoder.encode(v)) ?? Data()) }
    static func decode<T: Decodable>(_ t: T.Type, _ d: Data) -> T? { try? decoder.decode(t, from: Data(d.dropFirst())) }
}

// MARK: - Resumo falado (regras, sem LLM)

/// Transforma a resposta de um agente numa fala curta: 2 a 3 frases, nunca código, caminhos, tabelas ou URLs.
/// Prefere o último parágrafo de prosa (é onde Claude/Codex põem a conclusão).
enum SpokenSummary {
    static func make(_ text: String, maxSentences: Int = 3, maxWords: Int = 45) -> String {
        var s = text
        // Blocos de código fora.
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: "\n", options: .regularExpression)
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Parágrafos de prosa (sem tabelas, cabeçalhos ou linhas que são só caminhos/comandos).
        var paras: [[String]] = [[]]
        for l in lines {
            if l.isEmpty { paras.append([]); continue }
            if l.hasPrefix("|") || l.hasPrefix("#") || l.hasPrefix("---") || l.hasPrefix(">") { paras.append([]); continue }
            paras[paras.count - 1].append(l)
        }
        let prose = paras.map { p in p.map(clean).filter { $0.split(separator: " ").count >= 3 }.joined(separator: " ") }
            .filter { !$0.isEmpty }
        guard !prose.isEmpty else { return "" }
        // Último parágrafo; se for curto demais, junta o anterior.
        var chosen = prose.last!
        if chosen.split(separator: " ").count < 8, prose.count > 1 { chosen = prose[prose.count - 2] + " " + chosen }
        let sentences = splitSentences(chosen)
        var out: [String] = [], words = 0
        for x in sentences.prefix(maxSentences) {
            let w = x.split(separator: " ").count
            if !out.isEmpty, words + w > maxWords { break }
            out.append(x); words += w
        }
        var r = out.joined(separator: " ")
        if words > maxWords { r = r.split(separator: " ").prefix(maxWords).joined(separator: " ") + "." }
        return r
    }

    /// Frases que só apontam para um caminho ou link ("está em ~/x/y", "vê https://...") não se dizem em voz alta.
    static func clean(_ line: String) -> String {
        let ref = "(https?://\\S+|(~|\\.{0,2})?/[\\w.@~-]+(/[\\w.@~-]+)+/?)"
        let kept = splitSentences(line).filter { $0.range(of: ref, options: .regularExpression) == nil }
        return kept.map(cleanSentence).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func cleanSentence(_ line: String) -> String {
        var l = line
        l = l.replacingOccurrences(of: "^([-*+]|\\d+[.)])\\s+", with: "", options: .regularExpression) // marcas de lista
        l = l.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
        l = l.replacingOccurrences(of: "`[^`]*`", with: "", options: .regularExpression)               // código em linha
        l = l.replacingOccurrences(of: "(~|\\.{0,2})?/[\\w.@~-]+(/[\\w.@~-]+)+/?", with: "", options: .regularExpression) // caminhos
        l = l.replacingOccurrences(of: "\\b[\\w-]+\\.(swift|py|ts|tsx|js|json|md|yml|yaml|sh|plist|wav|m4a|txt)\\b", with: "", options: .regularExpression)
        l = l.replacingOccurrences(of: "[*_~]{1,3}", with: "", options: .regularExpression)            // ênfase markdown
        l = l.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        l = l.replacingOccurrences(of: "[—–]", with: ",", options: .regularExpression)
        l = l.replacingOccurrences(of: "\\(\\s*\\)", with: "", options: .regularExpression)
        l = l.replacingOccurrences(of: "\\s+([,.;:])", with: "$1", options: .regularExpression)
        l = l.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return l.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
    }

    static func splitSentences(_ t: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(t)
        for (i, ch) in chars.enumerated() {
            cur.append(ch)
            // Fim de frase só com espaço/fim a seguir ("exemplo.pt" e "1.5" não partem).
            if ".!?".contains(ch), i + 1 == chars.count || chars[i + 1].isWhitespace {
                let x = cur.trimmingCharacters(in: .whitespaces); if x.count > 1 { out.append(x) }; cur = ""
            }
        }
        let rest = cur.trimmingCharacters(in: .whitespaces)
        if rest.count > 1 { out.append(rest.hasSuffix(":") ? String(rest.dropLast()) + "." : rest + ".") }
        return out
    }
}

// MARK: - Deteção de voz (energia, sem modelo)

/// VAD por energia com chão de ruído adaptativo. Frames de 20 ms a 16 kHz.
/// Começo de fala: 3 frames seguidos acima do limiar. Fim de vez: `endSilence` segundos abaixo.
struct EnergyVAD {
    var endSilence: Double = 0.7
    private(set) var speaking = false
    private var noise: Float = 0.004
    private var above = 0, below = 0
    private var carry: [Float] = []
    static let frame = 320

    enum Event { case speechStart, speechEnd }

    mutating func feed(_ samples: [Float]) -> [Event] {
        carry += samples
        var ev: [Event] = []
        while carry.count >= Self.frame {
            let f = carry.prefix(Self.frame); carry.removeFirst(Self.frame)
            let rms = sqrt(f.reduce(0) { $0 + $1 * $1 } / Float(Self.frame))
            let thr = max(0.008, noise * 3.0)
            if rms > thr { above += 1; below = 0 } else { below += 1; above = 0; noise = rms < noise ? noise * 0.97 + rms * 0.03 : noise * 0.999 + rms * 0.001 } // sobe devagar: as pausas entre sílabas puxavam o chão até a voz contar como ruído
            if !speaking, above >= 3 { speaking = true; ev.append(.speechStart) }
            if speaking, Double(below) * 0.02 >= endSilence { speaking = false; ev.append(.speechEnd) }
        }
        return ev
    }
}

// MARK: - Frames da chamada

/// Frame cifrado da chamada: fio = LinkCrypto.frame(ChaChaPoly(dir + seq(UInt64 BE) + tipo + dados)).
/// Chave própria da chamada = HKDF(chave do código, id do pedido + nonce do Mac): frames de outra chamada não abrem.
/// `dir` impede reflexão (devolver ao iPhone o que ele mandou) e `seq` tem de subir sempre (anti-replay).
enum CallFrame {
    enum Kind: UInt8 {
        case mic = 0x61        // iPhone -> Mac: PCM Int16 16 kHz mono
        case tts = 0x6F        // Mac -> iPhone: PCM Int16 à taxa anunciada em "ttsRate"
        case event = 0x74      // JSON {state, text, ttsRate, ...}
        case stop = 0x78       // Mac -> iPhone: pára o áudio já (barge-in)
        case hangup = 0x68
        // Ecrã ao vivo (ScreenStream): o mesmo envelope cifrado da chamada.
        case video = 0x76      // Mac -> iPhone: 1 frame H.264 (ver ScreenStream.Frame)
        case ctrl = 0x63       // iPhone -> Mac: JSON (rato/teclas como RemoteInput.Cmd, "kf" keyframe, "mon" monitor)
    }
    static let up: UInt8 = 0x55, down: UInt8 = 0x44

    static func key(token: String, requestID: Data, nonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: LinkCrypto.key(token), salt: requestID + nonce,
                               info: Data("fala-call-v1".utf8), outputByteCount: 32)
    }

    static func seal(_ kind: Kind, _ payload: Data, dir: UInt8, seq: UInt64, key: SymmetricKey) -> Data {
        var p = Data([dir])
        withUnsafeBytes(of: seq.bigEndian) { p.append(contentsOf: $0) }
        p.append(kind.rawValue); p.append(payload)
        return LinkCrypto.frame(try! ChaChaPoly.seal(p, using: key).combined)
    }

    /// Tira um frame completo do buffer (nil se ainda não chegou todo). `bad` = adulterado / fora de ordem.
    struct Opener {
        let key: SymmetricKey, dir: UInt8
        private(set) var lastSeq: UInt64 = 0
        init(key: SymmetricKey, dir: UInt8) { self.key = key; self.dir = dir }
        enum Result { case frame(Kind, Data), incomplete, bad }
        mutating func next(_ buf: inout Data) -> Result {
            guard let n = LinkCrypto.frameLength(buf) else { return buf.count >= 6 ? .bad : .incomplete }
            guard buf.count >= n else { return .incomplete }
            let raw = Data(buf.prefix(n)); buf.removeFirst(n)
            guard let box = try? ChaChaPoly.SealedBox(combined: Data(raw.dropFirst(6))),
                  let p = try? ChaChaPoly.open(box, using: key), p.count >= 10, p[p.startIndex] == dir else { return .bad }
            let seq = p.dropFirst().prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard seq > lastSeq, let k = Kind(rawValue: p[p.startIndex + 9]) else { return .bad }
            lastSeq = seq
            return .frame(k, Data(p.dropFirst(10)))
        }
    }

    static func pcm16(_ s: [Float]) -> Data {
        var d = Data(capacity: s.count * 2)
        for x in s { var v = Int16(max(-1, min(1, x)) * 32767).littleEndian; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        return d
    }
    static func floats(_ d: Data) -> [Float] {
        var out = [Float](repeating: 0, count: d.count / 2)
        d.withUnsafeBytes { raw in for i in 0..<out.count { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32767 } }
        return out
    }
}

/// Estado que o Mac anuncia durante a chamada.
struct CallEvent: Codable {
    var state: String              // "ready" | "listening" | "heard" | "thinking" | "speaking" | "error" | "ended"
    var text: String?
    var ttsRate: Int?
    var image: String? = nil       // JPEG em base64: captura ou imagem que o agente fez (cartão na chamada)
}

/// De `a` para `b`: quantos Deletes no fim e que texto escrever a seguir (prefixo comum fica).
func textDiff(_ a: String, _ b: String) -> (deletes: Int, insert: String) {
    let same = zip(a, b).prefix { $0 == $1 }.count
    return (a.count - same, String(b.dropFirst(same)))
}
