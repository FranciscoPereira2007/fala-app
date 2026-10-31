import Foundation
import Security

/// Código e endereço do Mac partilhados entre a app e o widget (CarPlay) pelo Porta-chaves.
/// ponytail: Keychain em vez de App Group (App Group exige conta no Xcode; o perfil "*" já deixa o grupo do Porta-chaves).
enum FalaGroup {
    private static let group: String = {
        // Prefixo da equipa vem do próprio binário (AppIdentifierPrefix), igual na app e no widget.
        (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String ?? "") + "com.fran.fala.shared"
    }()
    static func get(_ k: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "fala", kSecAttrAccount as String: k,
                                kSecAttrAccessGroup as String: group, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ v: String, _ k: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "fala", kSecAttrAccount as String: k,
                                   kSecAttrAccessGroup as String: group]
        SecItemDelete(base as CFDictionary)
        var add = base; add[kSecValueData as String] = Data(v.utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
