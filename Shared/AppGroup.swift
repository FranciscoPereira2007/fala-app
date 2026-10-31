#if os(iOS)
import UIKit

/// Ponte app -> teclado pelo clipboard, com um tipo próprio para o teclado saber que é texto da Fala.
/// ponytail: clipboard em vez de App Group (App Group exige conta no Xcode); trocar se houver conta.
enum Shared {
    static let type = "com.fran.fala.pending"
    static var pending: String? {
        get {
            guard UIPasteboard.general.contains(pasteboardTypes: [type]),
                  let d = UIPasteboard.general.data(forPasteboardType: type) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        set {
            guard let t = newValue else { UIPasteboard.general.setItems([[:]]); return }
            UIPasteboard.general.setItems([[type: Data(t.utf8), "public.utf8-plain-text": t]],
                                          options: [.expirationDate: Date().addingTimeInterval(300)])
        }
    }
}
#endif
