import Foundation
import Security
import CCDeskCore

/// 推送密钥与助手接口密钥存在登录钥匙串里（generic password，service 为 `PushSecrets.service` /
/// `AssistantAPISettings.keychainService`）。条目由 CC Desk 自己创建，之后读取不弹授权。测试用 `InMemorySecretStore`。
final class KeychainSecretStore: SecretStore {
    static let push = KeychainSecretStore(service: PushSecrets.service, label: "CC Desk push")
    static let assistant = KeychainSecretStore(service: AssistantAPISettings.keychainService, label: "CC Desk assistant API")

    let service: String
    /// 钥匙串访问里显示的名字（后面加账户名）。
    let label: String

    init(service: String, label: String) {
        self.service = service
        self.label = label
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?, account: String) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "\(label) (\(account))"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
