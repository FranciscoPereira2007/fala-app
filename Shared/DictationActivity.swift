#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity do ditado com o ecrã bloqueado (a gravar / a enviar / colado no Mac).
struct DictationAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String      // "rec" | "send" | "done" | "fail"
        var text: String       // última frase (curta)
        var started: Date
    }
}
#endif
