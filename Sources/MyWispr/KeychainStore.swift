import Foundation
import Security

enum KeychainStore {
    private static let service = "com.abennat.mywispr"

    static func save(key: String, value: String) {
        saveData(key: key, data: Data(value.utf8))
    }

    static func saveData(key: String, data: Data) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        // Delete any existing item first, then add the new one.
        SecItemDelete(query as CFDictionary)
        if data.isEmpty { return }

        var attributes = query
        attributes[kSecValueData] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load(key: String) -> String {
        guard let data = loadData(key: key),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    static func loadData(key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return data
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
