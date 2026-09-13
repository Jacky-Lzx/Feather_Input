import Foundation
import Security
import LocalAuthentication

enum ModelCredential {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "im.feather.inputmethod.FeatherInput.LMStudio", kSecAttrAccount as String: "local-api-token"]
    // Loaded only when AI is enabled; never written to preferences or diagnostic output.
    private static var cached: String?
    static func read() -> String {
        if let cached { return cached }
        var q = query
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = authentication
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        let token = String(decoding: data, as: UTF8.self)
        cached = token
        return token
    }
    static func save(_ token: String) throws {
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        } else {
            let update = [kSecValueData as String: Data(token.utf8)]
            var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = Data(token.utf8)
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        cached = token
    }
}
