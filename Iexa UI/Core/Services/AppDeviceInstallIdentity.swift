import Foundation
import Security

enum AppDeviceInstallIdentity {
    private static let service = "com.iexa.ios.auth"
    private static let account = "device_install_id"
    private static let fallbackDefaultsKey = "iexa.device.install.id.fallback"

    static func currentID() -> String {
        if let existing = readFromKeychain(), !existing.isEmpty {
            return existing
        }

        if let fallback = UserDefaults.standard.string(forKey: fallbackDefaultsKey),
           !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = saveToKeychain(fallback)
            return fallback
        }

        let generated = UUID().uuidString.lowercased()
        if saveToKeychain(generated) {
            return generated
        }

        UserDefaults.standard.set(generated, forKey: fallbackDefaultsKey)
        return generated
    }

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    private static func saveToKeychain(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }

        return false
    }
}
