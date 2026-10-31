import Foundation

/// Limpeza determinística e local do ditado (pt-PT primeiro). Função pura, sem rede.
/// Ordem: pontuação falada, emails/sites, números/horas/moeda, bengalas, gaguez,
/// autocorreções ("às três, aliás, às quatro"), pontuação e maiúsculas.
enum TextCleanup {
    static func clean(_ raw: String, vocabulary: [String] = []) -> String {
        var s = raw.replacingOccurrences(of: "\r", with: "")
        s = normalizeEngine(s)
        s = spokenPunctuation(s)
        s = emails(s)
        s = slashCommands(s)
        var t = tokenize(s)
        t = numbers(t)
        t = fillers(t)
        t = stutter(t)
        t = corrections(t)
        t = applyVocabulary(t, vocabulary)
        return render(t)
    }

    /// Termos de dev que o Whisper em pt estraga ("emecêpê", "guit rub"). Vão também no prompt do Whisper.
    static let techTerms = ["MCP", "GitHub", "skill", "skills", "Claude", "Codex", "commit", "push", "deploy", "iTerm", "Tailscale", "Supabase", "Xcode", "prompt", "API", "bug", "build"]

    /// "barra edit" / "slash edit" -> "/edit" (comandos e skills nas sessões).
    static func slashCommands(_ s: String) -> String {
        s.replacingOccurrences(of: "(?i)\\b(?:barra|slash)\\s+([A-Za-zÀ-ÿ][\\w-]*)", with: "/$1", options: .regularExpression)
    }

    // MARK: - Vocabulário (nomes do dicionário): "Zira" -> "Zyra", "reps" -> "Repz"

    /// Chave fonética simples pt: sem acentos, y->i, z->s, k->c, w->v, ph->f, sem letras dobradas.
    static func phoneticKey(_ w: String) -> String {
        let w = w.lowercased().replacingOccurrences(of: "ã", with: "an").replacingOccurrences(of: "õ", with: "on")
        var k = w.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_PT")).lowercased()
        for (a, b) in [("ph", "f"), ("y", "i"), ("z", "s"), ("k", "c"), ("w", "v"), ("ç", "s"), ("qu", "c"), ("h", "")] { k = k.replacingOccurrences(of: a, with: b) }
        var out = ""; for c in k where c.isLetter || c.isNumber { if out.last != c { out.append(c) } }
        return out
    }

    private static func applyVocabulary(_ t: [String], _ vocab: [String]) -> [String] {
        let terms = vocab.filter { !$0.contains(" ") && $0.count >= 3 }
        guard !terms.isEmpty else { return t }
        var map: [String: String] = [:]
        for term in terms { map[phoneticKey(term)] = term }
        return t.map { tok in
            guard isWord(tok), tok.count >= 3, !tok.contains("@"), let term = map[phoneticKey(tok)] else { return tok }
            return term
        }
    }

    // MARK: - Manias dos motores (Whisper/Apple)

    private static func normalizeEngine(_ input: String) -> String {
        var s = input
        let rules: [(String, String)] = [
            ("^\\s*1\\.\\s+(?=\\p{Lu})", ""),                        // Whisper: "Hum," vira "1." no início
            ("[.,]?\\s*\\bFinal\\s*\\.\\s*$", "."),                // "... pão. Final." (ponto final mal ouvido)
            ("\\b(\\d{3})[-.](\\d{3})[-.](\\d{3})\\b", "$1 $2 $3"),  // 912-345-678
            ("(\\p{L}{3,})(\\d)", "$1 $2"), ("(\\d)(\\p{Ll}{3,})", "$1 $2"), // "cinco678", "mil200"
            ("\\b(\\p{L}+)mos-nos\\b", "$1mo-nos"),                  // "encontramos-nos" -> "encontramo-nos"
        ]
        for (p, r) in rules { s = s.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return s
    }

    // MARK: - Pontuação falada

    private static let numberish = "(?:\\d+|zero|um|uma|dois|duas|três|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|treze|catorze|quatorze|quinze|dezasseis|dezesseis|dezassete|dezessete|dezoito|dezanove|dezenove|vinte|trinta|quarenta|cinquenta|sessenta|setenta|oitenta|noventa|cem|cento)"

    private static func spokenPunctuation(_ input: String) -> String {
        var s = input
        // "dois vírgula cinco" é decimal: protege antes de trocar "vírgula" por ",".
        s = s.replacingOccurrences(of: "\\b(\(numberish))\\s+vírgula\\s+(\(numberish))\\b", with: "$1 ‹dec› $2", options: [.regularExpression, .caseInsensitive])
        let rules: [(String, String)] = [
            ("ponto de interrogação", "?"), ("ponto de exclamação", "!"), ("ponto e vírgula", ";"),
            ("ponto final", "."), ("novo parágrafo", "\n\n"), ("parágrafo novo", "\n\n"),
            ("nova linha", "\n"), ("mudar de linha", "\n"), ("muda de linha", "\n"),
            ("reticências", "…"), ("vírgula", ","),
            ("abre aspas", "“"), ("fecha aspas", "”"), ("abre parênteses", "("), ("fecha parênteses", ")"),
            ("abrir parênteses", "("), ("fechar parênteses", ")"),
        ]
        for (k, v) in rules {
            // Absorve a pontuação que o motor já tenha posto à volta da palavra falada.
            let lead = v.hasPrefix("\n") ? "" : "[,.;:]?"
            let p = lead + "\\s*\\b" + k.replacingOccurrences(of: " ", with: "\\s+") + "\\b\\s*[,.;:]?"
            let tpl = v == "\n" || v == "\n\n" ? v : " \(v) "
            s = s.replacingOccurrences(of: p, with: NSRegularExpression.escapedTemplate(for: tpl), options: [.regularExpression, .caseInsensitive])
        }
        // "dois pontos" só como pontuação quando vem texto a seguir (não "ganhou dois pontos").
        s = s.replacingOccurrences(of: "[,.]?\\s*\\bdois\\s+pontos\\b[,.]?\\s+(?=\\p{L})", with: " : ", options: [.regularExpression, .caseInsensitive])
        return s
    }

    // MARK: - Emails e sites

    private static let tlds = "com|pt|ai|io|net|org|app|dev|eu|br|co|me|info"

    private static func emails(_ input: String) -> String {
        var s = input
        let word = "[\\p{L}\\p{N}_-]+"
        // fran arroba repz ponto ai  /  Fran @ Repz . AI
        let dom = "\(word)(?:\\s*(?:\\bponto\\b|\\.)\\s*\(word))+"
        let re = try! NSRegularExpression(pattern: "(\(word)(?:(?:\\.|\\s+ponto\\s+)\(word))*)\\s*(?:\\barroba\\b|@)\\s*(\(dom))", options: [.caseInsensitive])
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s), let u = Range(m.range(at: 1), in: s), let d = Range(m.range(at: 2), in: s) else { continue }
            let user = squash(String(s[u])), domain = squash(String(s[d]))
            s.replaceSubrange(r, with: (user + "@" + domain).lowercased())
        }
        // repz ponto ai -> repz.ai
        s = s.replacingOccurrences(of: "\\b(\(word))\\s+ponto\\s+(\(tlds))\\b", with: "$1.$2", options: [.regularExpression, .caseInsensitive])
        let site = try! NSRegularExpression(pattern: "\\b[\\p{L}\\p{N}-]+\\.(?:\(tlds))\\b", options: [.caseInsensitive])
        for m in site.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            if let r = Range(m.range, in: s) { s.replaceSubrange(r, with: s[r].lowercased()) }
        }
        return s
    }

    private static func squash(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s*\\bponto\\b\\s*", with: ".", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s*\\.\\s*", with: ".", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Tokens

    private static let punct: Set<String> = [",", ".", "!", "?", ";", ":", "…", "\n", "(", ")", "“", "”"]
    private static let sentenceEnd: Set<String> = [".", "!", "?", "\n", "…"]

    static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(s)
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for (i, c) in chars.enumerated() {
            if c == "\n" { flush(); out.append("\n"); continue }
            if c.isWhitespace { flush(); continue }
            if ",.:;".contains(c) {
                // Mantém "45,50", "9:30", "repz.ai", "25.000" dentro da palavra.
                let prev = i > 0 ? chars[i - 1] : " ", next = i + 1 < chars.count ? chars[i + 1] : " "
                if !cur.isEmpty, (prev.isLetter || prev.isNumber), (next.isLetter || next.isNumber),
                   (c == "." || prev.isNumber && next.isNumber) { cur.append(c); continue }
                flush(); out.append(String(c)); continue
            }
            if "!?…()“”\"".contains(c) { flush(); if c != "\"" { out.append(String(c)) }; continue }
            cur.append(c)
        }
        flush()
        return out
    }

    private static func isWord(_ t: String) -> Bool { !punct.contains(t) && t != "‹dec›" }
    private static func low(_ t: String) -> String { t.lowercased() }

    // MARK: - Números

    private static let units: [String: Int] = [
        "zero": 0, "um": 1, "uma": 1, "dois": 2, "duas": 2, "três": 3, "quatro": 4, "cinco": 5, "seis": 6,
        "sete": 7, "oito": 8, "nove": 9, "dez": 10, "onze": 11, "doze": 12, "treze": 13, "catorze": 14,
        "quatorze": 14, "quinze": 15, "dezasseis": 16, "dezesseis": 16, "dezassete": 17, "dezessete": 17,
        "dezoito": 18, "dezanove": 19, "dezenove": 19,
        "vinte": 20, "trinta": 30, "quarenta": 40, "cinquenta": 50, "sessenta": 60, "setenta": 70,
        "oitenta": 80, "noventa": 90, "cem": 100, "cento": 100, "duzentos": 200, "duzentas": 200,
        "trezentos": 300, "trezentas": 300, "quatrocentos": 400, "quatrocentas": 400, "quinhentos": 500,
        "quinhentas": 500, "seiscentos": 600, "seiscentas": 600, "setecentos": 700, "setecentas": 700,
        "oitocentos": 800, "oitocentas": 800, "novecentos": 900, "novecentas": 900,
    ]
    private static let scales: [String: Int] = ["mil": 1000, "milhão": 1_000_000, "milhões": 1_000_000]

    private static func wordValue(_ t: String) -> Int? { units[low(t)] }
    private static func digitValue(_ t: String) -> Int? {
        // "25.000" (milhares pt) ou "25000"
        if t.range(of: "^\\d{1,3}(\\.\\d{3})+$", options: .regularExpression) != nil { return Int(t.replacingOccurrences(of: ".", with: "")) }
        if t.range(of: "^\\d{1,9}$", options: .regularExpression) != nil { return Int(t) }
        return nil
    }
    private static func isNumberToken(_ t: String) -> Bool { wordValue(t) != nil || scales[low(t)] != nil || digitValue(t) != nil }

    /// Lê um número a partir de i: devolve (valor, fim exclusivo, só palavras?).
    private static func parseNumber(_ t: [String], _ i: Int) -> (Int, Int, Bool)? {
        if let d = digitValue(t[i]) {
            // "25 mil"
            if i + 1 < t.count, let sc = scales[low(t[i + 1])] { return (d * sc, i + 2, false) }
            return (d, i + 1, false)
        }
        guard wordValue(t[i]) != nil || scales[low(t[i])] != nil else { return nil }
        var total = 0, current = 0, j = i, lastPart = Int.max
        while j < t.count {
            let w = low(t[j])
            if let v = units[w] ?? (lastPart >= 100 && lastPart != Int.max ? digitValue(t[j]) : nil) {
                guard v < lastPartGranularity(lastPart) else { break }
                current += v; lastPart = v; j += 1
            } else if let sc = scales[w] {
                current = max(current, 1) * sc
                if sc >= 1000 { total += current; current = 0 }
                lastPart = sc; j += 1
            } else if w == "e", j + 1 < t.count, let nv = units[low(t[j + 1])] ?? scales[low(t[j + 1])].map({ _ in -1 }),
                      nv >= 0, nv < lastPartGranularity(lastPart), lastPart >= 20 {
                j += 1
            } else { break }
        }
        guard j > i else { return nil }
        return (total + current, j, true)
    }

    /// Depois de "vinte" só cabem unidades; depois de "cem" até 99; depois de "mil" até 999.
    private static func lastPartGranularity(_ last: Int) -> Int {
        if last == Int.max { return Int.max }
        if last >= 1_000_000 { return 1_000_000 }
        if last >= 1000 { return 1000 }
        if last >= 100 { return 100 }
        if last >= 20 { return 10 }
        return 0 // depois de unidades (1-19) não se junta mais nada
    }

    static func group(_ n: Int) -> String {
        let s = String(n)
        guard n >= 10000 else { return s }
        var out = "", c = 0
        for ch in s.reversed() { if c > 0 && c % 3 == 0 { out.append(" ") }; out.append(ch); c += 1 }
        return String(out.reversed())
    }

    private static let timePrev: Set<String> = ["às", "as", "pelas", "das", "até", "à"]
    private static let dayPart: [String: Int] = ["manhã": 0, "tarde": 12, "noite": 12, "madrugada": 0]

    private static func numbers(_ input: [String]) -> [String] {
        var t = input
        // Horas já em dígitos: 9:30 -> 9h30, 16:00 -> 16h
        t = t.map { tok in
            guard let m = tok.range(of: "^(\\d{1,2}):(\\d{2})$", options: .regularExpression) else { return tok }
            let p = tok[m].split(separator: ":"); let h = Int(p[0])!, mi = Int(p[1])!
            return h < 25 && mi < 60 ? (mi == 0 ? "\(h)h" : "\(h)h" + String(format: "%02d", mi)) : tok
        }
        var out: [String] = [], i = 0
        while i < t.count {
            // "45,50 euros" -> "45,50 €"
            if t[i].range(of: "^\\d+,\\d{1,2}$", options: .regularExpression) != nil, i + 1 < t.count, ["euros", "euro"].contains(low(t[i + 1])) {
                out.append(t[i] + " €"); i += 2; continue
            }
            // Telefone: 6+ algarismos ditos um a um (vírgulas pelo meio são pausas).
            if let (digits, end) = digitRun(t, i), digits.count >= 6 {
                out.append(digits.count == 9 ? stride(from: 0, to: 9, by: 3).map { Array(digits)[$0..<$0 + 3] }.map { String($0) }.joined(separator: " ") : digits)
                i = end; continue
            }
            guard let (v, end, words) = parseNumber(t, i) else { out.append(t[i]); i += 1; continue }
            var j = end
            var numStr = group(v)
            // decimal falado: "dois ‹dec› cinco"
            if j < t.count, t[j] == "‹dec›", j + 1 < t.count, let (d, e2, _) = parseNumber(t, j + 1) {
                numStr += ",\(d)"; j = e2
                let n2 = j < t.count ? low(t[j]) : ""
                if n2 == "%" || (n2 == "por" && j + 1 < t.count && low(t[j + 1]) == "cento") { out.append(numStr + "%"); i = j + (n2 == "%" ? 1 : 2); continue }
                if n2 == "euros" || n2 == "euro" { out.append(numStr + " €"); i = j + 1; continue }
                out.append(numStr); i = j; continue
            }
            let next = j < t.count ? low(t[j]) : ""
            let prev = out.last.map(low) ?? ""
            // Moeda
            if next == "euros" || next == "euro" || next == "€" {
                j += 1; var cents = 0
                if j + 2 < t.count, low(t[j]) == "e", let (c, e2, _) = parseNumber(t, j + 1), e2 < t.count, low(t[e2]).hasPrefix("cêntimo") {
                    cents = c; j = e2 + 1
                }
                out.append(group(v) + (cents > 0 ? "," + String(format: "%02d", cents) : "") + " €"); i = j; continue
            }
            // Percentagem
            if next == "%" || (next == "por" && j + 1 < t.count && low(t[j + 1]) == "cento") {
                out.append("\(group(v))%"); i = j + (next == "%" ? 1 : 2); continue
            }
            // Horas: "às nove e meia", "às quatro da tarde", "às 10 horas"
            if timePrev.contains(prev), v <= 24 {
                var h = v, m = -1, k = j
                if k < t.count, ["horas", "hora", "h"].contains(low(t[k])) { m = 0; k += 1 }
                if k + 1 < t.count, low(t[k]) == "e" {
                    let w = low(t[k + 1])
                    if w == "meia" { m = 30; k += 2 }
                    else if w == "um", k + 2 < t.count, low(t[k + 2]) == "quarto" { m = 15; k += 3 }
                    else if let (mm, e2, _) = parseNumber(t, k + 1), mm < 60 {
                        m = mm; k = e2; if k < t.count, low(t[k]).hasPrefix("minuto") { k += 1 }
                    }
                }
                if k + 1 < t.count, ["da", "de"].contains(low(t[k])), let add = dayPart[low(t[k + 1])] {
                    if add > 0, h < 12, !(low(t[k + 1]) == "noite" && h < 6) { h += add }
                    m = max(m, 0); k += 2
                }
                if m >= 0 || v >= 10 {
                    out.append(m <= 0 ? "\(h)h" : "\(h)h" + String(format: "%02d", m)); i = k; continue
                }
            }
            // Resto: 0-9 ditos ficam por extenso, 10+ em algarismos.
            if words && v < 10 { out.append(contentsOf: t[i..<end]) }
            else { out.append(group(v)) }
            i = end
        }
        return out.filter { $0 != "‹dec›" }
    }

    private static func digitRun(_ t: [String], _ i: Int) -> (String, Int)? {
        var digits = "", j = i, last = i
        while j < t.count {
            if let v = units[low(t[j])], v < 10 { digits += String(v); j += 1; last = j }
            else if t[j].range(of: "^\\d+$", options: .regularExpression) != nil, t[j].count <= 4, t[j].count > 1 || !digits.isEmpty || (j + 1 < t.count && t[j + 1].first?.isNumber == true) {
                digits += t[j]; j += 1; last = j
            } else if t[j] == ",", !digits.isEmpty { j += 1 } else { break }
        }
        return digits.isEmpty ? nil : (digits, last)
    }

    // MARK: - Bengalas (fillers)

    private static let pureFillers: Set<String> = ["hum", "humm", "hummm", "hmm", "hm", "ã", "ãh", "ãã", "ããã", "eh", "éh", "uh", "uhm", "hã", "ahn", "hmmm", "mm", "mmm", "uhum", "ah", "ahh", "aah"]
    private static let tipoKeepPrev: Set<String> = ["o", "um", "que", "este", "esse", "aquele", "de", "do", "da", "qualquer", "mesmo", "outro", "bom", "mau", "novo", "certo", "esse", "deste", "desse", "nesse", "neste", "algum", "nenhum", "cada", "seu", "teu", "meu"]

    private static func fillers(_ input: [String]) -> [String] {
        var t = input
        var removed = Array(repeating: false, count: t.count)
        func prevIdx(_ i: Int) -> Int? { var k = i - 1; while k >= 0, removed[k] || t[k] == "," { k -= 1 }; return k >= 0 ? k : nil }
        func clauseStart(_ i: Int) -> Bool {
            var k = i - 1; while k >= 0, removed[k] { k -= 1 }
            return k < 0 || sentenceEnd.contains(t[k]) || t[k] == "," || t[k] == ":" || t[k] == ";"
        }
        func nextWord(_ i: Int, _ off: Int = 1) -> String {
            var k = i + 1, n = 0
            while k < t.count { if t[k] != "," { n += 1; if n == off { return low(t[k]) } }; k += 1 }
            return ""
        }
        func isFillerAt(_ i: Int) -> Bool {
            let w = low(t[i])
            return pureFillers.contains(w) || (w == "é" && i + 1 < t.count && low(t[i + 1]) == "assim") || w == "pronto" || w == "tipo"
        }
        for i in t.indices where !removed[i] {
            let w = low(t[i])
            if pureFillers.contains(w) { removed[i] = true; continue }
            switch w {
            case "tipo":
                let p = prevIdx(i).map { low(t[$0]) } ?? ""
                let n = nextWord(i)
                if !tipoKeepPrev.contains(p), n != "de", n != "", !sentenceEnd.contains(n) {
                    removed[i] = true
                    if n == "assim", let k = (i + 1..<t.count).first(where: { low(t[$0]) == "assim" }) { removed[k] = true }
                }
            case "pronto":
                let n = nextWord(i)
                let atEnd = n == "" || sentenceEnd.contains(n) || (i + 1 < t.count && sentenceEnd.contains(t[i + 1]))
                if clauseStart(i), !["para", "a", "?"].contains(n), !(i + 1 < t.count && t[i + 1] == "?") { removed[i] = true }
                else if atEnd, let p = prevIdx(i), low(t[p]) == "e", !(i + 1 < t.count && t[i + 1] == "?") { removed[i] = true; removed[p] = true }
            case "portanto":
                let k = (i + 1..<t.count).first(where: { t[$0] != "," })
                let nextIsFiller = k.map { isFillerAt($0) } ?? false
                let atEnd = k == nil || sentenceEnd.contains(t[k!])
                if (clauseStart(i) && nextIsFiller) || (atEnd && i > 0 && t[i - 1] == ",") { removed[i] = true }
            case "é":
                if i + 1 < t.count, low(t[i + 1]) == "assim", clauseStart(i) {
                    let n = nextWord(i, 2)
                    if !["que", "mesmo", "porque", "tão", ""].contains(n), !(i + 2 < t.count && sentenceEnd.contains(t[i + 2])) {
                        removed[i] = true; removed[i + 1] = true
                    }
                }
            default: break
            }
        }
        // Tira as vírgulas que só existiam à volta das bengalas.
        var out: [String] = []
        var i = 0
        while i < t.count {
            if removed[i] {
                var j = i; while j < t.count, removed[j] || t[j] == "," { j += 1 }
                let hadCommaBefore = out.last == ","
                let nextTok = j < t.count ? t[j] : nil
                if hadCommaBefore, let p = out.dropLast().last, ["e", "ou", "mas", "que", "de", "a", "o", "com", "para"].contains(low(p)) { out.removeLast() }
                else if hadCommaBefore, nextTok == nil || sentenceEnd.contains(nextTok!) { out.removeLast() }
                i = j; continue
            }
            out.append(t[i]); i += 1
        }
        while let f = out.first, f == "," { out.removeFirst() }
        return out
    }

    // MARK: - Gaguez: "o o projeto" -> "o projeto"

    private static let stutterWords: Set<String> = ["o", "a", "os", "as", "e", "eu", "de", "do", "da", "que", "um", "uma", "é", "no", "na", "se", "em", "para", "com", "isto", "isso", "ele", "ela", "tu", "nós", "mas", "então"]

    private static func stutter(_ t: [String]) -> [String] {
        var out: [String] = []
        for w in t {
            if let l = out.last, low(l) == low(w), stutterWords.contains(low(w)) { continue }
            out.append(w)
        }
        return out
    }

    // MARK: - Autocorreções

    private static let markers: [[String]] = [["aliás"], ["quer", "dizer"], ["ou", "melhor"], ["digo"], ["perdão"], ["melhor", "dizendo"], ["ou", "antes"]]
    private static let prepClasses: [Set<String>] = [
        ["em", "no", "na", "nos", "nas", "num", "numa", "neste", "nesta"],
        ["a", "à", "às", "ao", "aos", "para", "pra", "pro", "até"],
        ["de", "do", "da", "dos", "das"],
        ["por", "pelo", "pela", "pelos", "pelas"],
        ["o", "a", "os", "as", "um", "uma"],
    ]

    private static func sameClass(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if isNumberToken(a) || a.range(of: "^\\d", options: .regularExpression) != nil {
            return isNumberToken(b) || b.range(of: "^\\d", options: .regularExpression) != nil
        }
        return prepClasses.contains { $0.contains(a) && $0.contains(b) }
    }

    private static func corrections(_ input: [String]) -> [String] {
        var t = input
        var i = 0
        while i < t.count {
            guard let mk = markers.first(where: { m in i + m.count <= t.count && m.indices.allSatisfy { low(t[i + $0]) == m[$0] } }) else { i += 1; continue }
            // "o que quer dizer", "eu digo que": não são correções.
            if i > 0, ["que", "eu", "te", "lhe", "vos", "já", "isso", "isto"].contains(low(t[i - 1])) { i += 1; continue }
            var c = i + mk.count; while c < t.count, t[c] == "," { c += 1 }
            guard c < t.count, isWord(t[c]) else { i += 1; continue }
            let first = low(t[c])
            var b = i - 1; while b >= 0, t[b] == "," { b -= 1 }
            // procura âncora: mesma palavra primeiro, depois mesma classe; até 7 palavras, na mesma frase
            var anchor: Int? = nil
            for pass in 0..<2 {
                var k = b, seen = 0
                while k >= 0, seen < 7, !sentenceEnd.contains(t[k]) {
                    if isWord(t[k]) {
                        let w = low(t[k])
                        if pass == 0 ? w == first : sameClass(first, w) { anchor = k; break }
                        seen += 1
                    }
                    k -= 1
                }
                if anchor != nil { break }
            }
            guard let a = anchor else { i += 1; continue }
            // Mantém a maiúscula se a âncora abria a frase.
            if a == 0 || sentenceEnd.contains(t[a - 1]), let f = t[c].first { t[c] = String(f).uppercased() + t[c].dropFirst() }
            t.removeSubrange(a..<c)
            i = a + 1
        }
        return t
    }

    // MARK: - Render, pontuação e maiúsculas

    private static let lowerNames: Set<String> = ["segunda", "terça", "quarta", "quinta", "sexta", "sábado", "domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira",
        "janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"]
    private static let questionStarts = ["podes", "pode", "podem", "consegues", "consegue", "será que", "queres", "quer", "achas que", "qual", "quais", "quem", "onde", "porque é que", "o que é que", "sabes se", "é possível", "como é que", "quanto", "quantos", "quantas", "quando é que"]

    static func render(_ input: [String]) -> String {
        // limpa pontuação duplicada/encostada
        var t: [String] = []
        for tok in input {
            if let l = t.last, punct.contains(tok), tok != "\n", tok != "(", tok != "“" {
                if l == "\n" || l == "(" || l == "“" { continue }
                if [",", ";", ":"].contains(l), tok != "," { t[t.count - 1] = tok; continue } // ", ." -> "."
                if [".", "!", "?", "…"].contains(l), [",", ".", ";", ":"].contains(tok) { continue } // "?." -> "?"
                if l == tok { continue }
            }
            if t.isEmpty, punct.contains(tok), tok != "(", tok != "“" { continue }
            t.append(tok)
        }
        while let l = t.last, [",", ";", ":"].contains(l) || l == "\n" { t.removeLast() }
        guard !t.isEmpty else { return "" }

        // dias e meses em minúscula a meio da frase (pt-PT)
        for i in t.indices where i > 0 && !sentenceEnd.contains(t[i - 1]) {
            if lowerNames.contains(low(t[i])) { t[i] = low(t[i]) }
        }
        // maiúsculas no início de frase
        var capNext = true
        for i in t.indices {
            let tok = t[i]
            if sentenceEnd.contains(tok) { capNext = true; continue }
            if punct.contains(tok) { continue }
            if capNext, !tok.contains("@"), tok.range(of: "\\.(\(tlds))$", options: [.regularExpression, .caseInsensitive]) == nil, let f = tok.first {
                t[i] = String(f).uppercased() + tok.dropFirst()
            }
            capNext = false
        }

        // frases interrogativas sem "?"
        var start = 0
        for i in 0...t.count {
            let atEnd = i == t.count || sentenceEnd.contains(t[i])
            guard atEnd else { continue }
            if i > start {
                let words = t[start..<i].filter(isWord).map(low)
                let head = words.prefix(3).joined(separator: " ")
                if questionStarts.contains(where: { head == $0 || head.hasPrefix($0 + " ") }), i < t.count ? t[i] == "." : true, words.count >= 3 {
                    if i < t.count { t[i] = "?" } else { t.append("?") }
                }
            }
            start = i + 1
        }

        // ponto final se faltar (exceto despedida curta numa linha própria)
        if let l = t.last, isWord(l) || l == ")" || l == "”" {
            let lastLine = t.split(separator: "\n", omittingEmptySubsequences: false).last ?? []
            let hasNewline = t.contains("\n")
            if !(hasNewline && lastLine.filter(isWord).count <= 3) && t.filter(isWord).count >= 2 { t.append(".") }
        }

        var s = ""
        for (i, tok) in t.enumerated() {
            if tok == "\n" { while s.hasSuffix(" ") { s.removeLast() }; s += "\n"; continue }
            let prev = i > 0 ? t[i - 1] : "\n"
            let attach = [",", ".", "!", "?", ";", ":", "…", ")", "”"].contains(tok)
            if !s.isEmpty, !attach, prev != "\n", prev != "(", prev != "“" { s += " " }
            s += tok
        }
        return s
    }
}

#if DEBUG
/// Auto-teste: `TextCleanup.selfCheck()` (corre no arranque em Debug e no FalaBench).
extension TextCleanup {
    static let cases: [(String, String)] = [
        ("Olá Fran, a reunião com a Zyra fica marcada para amanhã às três, aliás, às quatro da tarde.", "Olá Fran, a reunião com a Zyra fica marcada para amanhã às 16h."),
        ("Hum, preciso de comprar dois quilos de arroz e, tipo, uma garrafa de azeite.", "Preciso de comprar dois quilos de arroz e uma garrafa de azeite."),
        ("O meu email é fran arroba repz ponto ai.", "O meu email é fran@repz.ai."),
        ("O meu email é Fran @ Repz.AI", "O meu email é fran@repz.ai."),
        ("A Repz AI faturou vinte e cinco mil euros este mês, mais quinze por cento do que em setembro.", "A Repz AI faturou 25 000 € este mês, mais 15% do que em setembro."),
        ("Caro Pedro vírgula obrigado pela reunião de ontem ponto final nova linha cumprimentos vírgula Fran", "Caro Pedro, obrigado pela reunião de ontem.\nCumprimentos, Fran"),
        ("Portanto, é assim, o projeto está quase pronto, mas falta testar no iPhone.", "O projeto está quase pronto, mas falta testar no iPhone."),
        ("Liga-me às nove e meia para o número nove um dois, três quatro cinco, seis sete oito.", "Liga-me às 9h30 para o número 912 345 678."),
        ("liga-me às 9:30 para o número 912345678", "Liga-me às 9h30 para o número 912 345 678."),
        ("A consulta custa quarenta e cinco euros e cinquenta cêntimos.", "A consulta custa 45,50 €."),
        ("Encontramo-nos no Porto, quer dizer, em Coimbra, na terça.", "Encontramo-nos em Coimbra, na terça."),
        ("Hum, ã, acho que a Zyra devia ligar às clínicas de manhã.", "Acho que a Zyra devia ligar às clínicas de manhã."),
        ("Compra o bilhete para dia vinte e três de dezembro.", "Compra o bilhete para dia 23 de dezembro."),
        ("O treino de hoje é peito e costas, quatro séries de doze repetições.", "O treino de hoje é peito e costas, quatro séries de 12 repetições."),
        ("podes confirmar se a reunião ainda está de pé", "Podes confirmar se a reunião ainda está de pé?"),
        ("Lista de compras dois pontos leite vírgula ovos vírgula pão ponto final", "Lista de compras: leite, ovos, pão."),
        ("Pronto, então fica combinado, eu trato do site e tu tratas dos anúncios.", "Então fica combinado, eu trato do site e tu tratas dos anúncios."),
        ("O orçamento é de mil e duzentos euros, digo, mil e quinhentos euros, com IVA incluído.", "O orçamento é de 1500 €, com IVA incluído."),
        ("o orçamento é de 1200 euros digo 1500 euros", "O orçamento é de 1500 €."),
        // não estragar o que é legítimo
        ("Que tipo de carro tens?", "Que tipo de carro tens?"),
        ("O jantar está pronto.", "O jantar está pronto."),
        ("Portanto, vamos avançar com o plano.", "Portanto, vamos avançar com o plano."),
        ("A vida é assim.", "A vida é assim."),
        ("O projeto, aliás, está atrasado.", "O projeto, aliás, está atrasado."),
        ("O que quer dizer isto?", "O que quer dizer isto?"),
        ("Ganhámos dois pontos.", "Ganhámos dois pontos."),
        ("Tenho dois filhos e três cães.", "Tenho dois filhos e três cães."),
        ("Nasci em dois mil e sete.", "Nasci em 2007."),
        ("O valor é dois vírgula cinco por cento.", "O valor é 2,5%."),
        ("Vemo-nos às dez da noite e pronto.", "Vemo-nos às 22h."),
        ("o o projeto está está feito", "O projeto está está feito."),
        ("Visita repz ponto ai", "Visita repz.ai."),
        ("Liga à Zira e à equipa da reps", "Liga à Zyra e à equipa da Repz."),
        ("1. Ah, acho que a Zyra devia ligar às clínicas de manhã.", "Acho que a Zyra devia ligar às clínicas de manhã."),
        ("Liga-me às 9h30 para o número 912-345-678.", "Liga-me às 9h30 para o número 912 345 678."),
        ("A consulta custa 45,50 euros.", "A consulta custa 45,50 €."),
        ("Encontramos-nos em Coimbra, na Terça.", "Encontramo-nos em Coimbra, na terça."),
        ("Lista de compras: leite, ovos, pão. Final.", "Lista de compras: leite, ovos, pão."),
        ("O orçamento é de mil200 euros, digo, 1500 €, com IVA incluído.", "O orçamento é de 1500 €, com IVA incluído."),
        ("o número nove um dois três quatro cinco678", "O número 912 345 678."),
        ("Cumprimentos, frã.", "Cumprimentos, Fran."),
        ("Usa barra edit e depois slash tim-gabe", "Usa /edit e depois /tim-gabe."),
    ]

    @discardableResult static func selfCheck() -> Int {
        var fails = 0
        for (i, o) in cases {
            let got = clean(i, vocabulary: ["Zyra", "Repz", "Repz AI", "Fran"])
            if got != o { fails += 1; print("✗ TextCleanup\n  in:   \(i)\n  want: \(o)\n  got:  \(got)") }
        }
        print("TextCleanup.selfCheck: \(cases.count - fails)/\(cases.count) ok")
        return fails
    }
}
#endif
