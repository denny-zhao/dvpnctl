import Foundation
import Security

struct KeychainVPNPasswords: VPNPasswordStore {
    var service = "local.it-admin.dvpnctl.vpn-password"

    func read(for id: UUID) throws -> VPNCredential? {
        var query = attributes(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw VPNError("Could not read the VPN password from Keychain.", "无法读取钥匙串中的 VPN 密码。") }
        return try? JSONDecoder().decode(VPNCredential.self, from: data)
    }

    func write(_ credential: VPNCredential, for id: UUID) throws {
        let query = attributes(for: id)
        let value = [kSecValueData as String: try JSONEncoder().encode(credential)]
        let status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(value) { _, new in new }
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func remove(for id: UUID) throws {
        let status = SecItemDelete(attributes(for: id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func attributes(for id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    private func check(_ status: OSStatus) throws {
        guard status != errSecSuccess else { return }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
        throw VPNError("Could not access macOS Keychain: \(message)", "无法访问 macOS 钥匙串：\(message)")
    }
}
