import Foundation
import Security

/// 使用系统钥匙串（Keychain）保存服务器 API Key，避免以明文写入 data.json。
enum KeychainStore {
    static let apiKeyService = "LocalAIChat.server-api-key"

    /// 读取某个服务器的 API Key。没有保存过（或读取失败）时返回 nil。
    static func apiKey(for serverID: UUID) -> String? {
        var query = baseQuery(account: serverID.uuidString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                print("读取钥匙串失败：\(status)")
            }
            return nil
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 保存某个服务器的 API Key；空字符串表示删除。成功时返回 true。
    @discardableResult
    static func setAPIKey(_ key: String, for serverID: UUID) -> Bool {
        if key.isEmpty {
            return deleteAPIKey(for: serverID)
        }
        let account = serverID.uuidString
        let data = Data(key.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        var status = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(account: account)
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        if status != errSecSuccess {
            print("写入钥匙串失败：\(status)")
        }
        return status == errSecSuccess
    }

    /// 删除某个服务器的 API Key。条目本来就不存在也视为成功。
    @discardableResult
    static func deleteAPIKey(for serverID: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(account: serverID.uuidString) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("删除钥匙串条目失败：\(status)")
            return false
        }
        return true
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: apiKeyService,
            kSecAttrAccount as String: account,
        ]
    }
}
