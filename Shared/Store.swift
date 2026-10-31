import Foundation

struct Entry: Codable, Identifiable {
    var id = UUID()
    var text: String
    var date = Date()
    var toMac = false
    var seconds: Double? = nil
    var words: Int { text.split(whereSeparator: \.isWhitespace).count }
}

@MainActor final class Store: ObservableObject {
    @Published private(set) var entries: [Entry] = []
    private let key = "fala.entries"

    init() {
        if Demo.on { entries = Demo.entries; return }
        if let d = UserDefaults.standard.data(forKey: key),
           let e = try? JSONDecoder().decode([Entry].self, from: d) { entries = e }
    }

    func add(_ text: String, toMac: Bool = false, seconds: Double? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        entries.insert(Entry(text: t, toMac: toMac, seconds: seconds), at: 0)
        if let d = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(d, forKey: key) }
    }

    var wordsToday: Int { entries.filter { Calendar.current.isDateInToday($0.date) }.reduce(0) { $0 + $1.words } }
    var wordsWeek: Int {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return entries.filter { $0.date >= start }.reduce(0) { $0 + $1.words }
    }
    // ~40 wpm a escrever vs ~150 a falar: minutos poupados.
    var minutesSaved: Int { Int(Double(entries.reduce(0) { $0 + $1.words }) * (1.0/40 - 1.0/150)) }
    var totalWords: Int { entries.reduce(0) { $0 + $1.words } }
    var wpm: Int {
        let timed = entries.filter { ($0.seconds ?? 0) > 1 }
        let secs = timed.reduce(0) { $0 + ($1.seconds ?? 0) }
        return secs > 0 ? Int(Double(timed.reduce(0) { $0 + $1.words }) / secs * 60) : 0
    }
    var streak: Int {
        let cal = Calendar.current
        let days = Set(entries.map { cal.startOfDay(for: $0.date) })
        var d = cal.startOfDay(for: Date()), n = 0
        if !days.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d)! }
        while days.contains(d) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return n
    }

    // Dicionário: palavra ouvida -> palavra certa. Snippets: gatilho falado -> texto expandido.
    @Published var dictionary: [String: String] = UserDefaults.standard.dictionary(forKey: "fala.dict") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(dictionary, forKey: "fala.dict") }
    }
    @Published var snippets: [String: String] = UserDefaults.standard.dictionary(forKey: "fala.snip") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(snippets, forKey: "fala.snip") }
    }
    @Published var scratchpad: String = UserDefaults.standard.string(forKey: "fala.scratch") ?? "" {
        didSet { UserDefaults.standard.set(scratchpad, forKey: "fala.scratch") }
    }

    /// Estilo por defeito (como o Flow): formal, casual, muito casual, entusiasmado.
    @Published var style: String = UserDefaults.standard.string(forKey: "fala.style") ?? "Formal" {
        didSet { UserDefaults.standard.set(style, forKey: "fala.style") }
    }
    static let styles: [(String, String, String)] = [
        ("Formal", "Maiúsculas + pontuação", "Olá, chego em 10 minutos."),
        ("Casual", "Maiúsculas + menos pontuação", "Olá chego em 10 minutos"),
        ("muito casual", "sem maiúsculas, sem pontuação", "olá chego em 10 minutos"),
        ("Entusiasmado!", "Maiúsculas + pontuação", "Olá! Chego em 10 minutos!")]

    func styled(_ t: String) -> String {
        switch style {
        case "Casual": return t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
        case "muito casual": return t.lowercased().filter { !".,!?;:".contains($0) }
        case "Entusiasmado!": return t.replacingOccurrences(of: ".", with: "!")
        default: return t
        }
    }

    /// Limpa o ditado (TextCleanup) e aplica dicionário e snippets (case-insensitive) ao texto transcrito.
    func process(_ text: String) -> String {
        var t = TextCleanup.clean(text, vocabulary: Array(dictionary.values))
        for (k, v) in dictionary.merging(snippets, uniquingKeysWith: { _, s in s }) where !k.isEmpty {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: k) + "\\b"
            t = t.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: v), options: [.regularExpression, .caseInsensitive])
        }
        return styled(t)
    }

    static let weeklyGoal = 2000 // ponytail: meta fixa, tornar editável se o Fran pedir
}
