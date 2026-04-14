import Foundation
import Security
import HFShared

public enum KeychainError: Error, Sendable {
    case duplicateItem
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case encodingError
}

public struct KeychainManager: Sendable {
    private let service: String

    public init(service: String = HFConstants.Security.keychainService) {
        self.service = service
    }

    public func save(key: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                SecurityAuditLogger.logDataProtection("keychain_update_failed: key=\(key) status=\(updateStatus)")
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            SecurityAuditLogger.logDataProtection("keychain_update: key=\(key)")
        } else if status != errSecSuccess {
            SecurityAuditLogger.logDataProtection("keychain_save_failed: key=\(key) status=\(status)")
            throw KeychainError.unexpectedStatus(status)
        } else {
            SecurityAuditLogger.logDataProtection("keychain_save: key=\(key)")
        }
    }

    public func load(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return result as? Data
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            SecurityAuditLogger.logDataProtection("keychain_delete_failed: key=\(key) status=\(status)")
            throw KeychainError.unexpectedStatus(status)
        }
        SecurityAuditLogger.logDataProtection("keychain_delete: key=\(key)")
    }

    public func saveString(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingError
        }
        try save(key: key, data: data)
    }

    public func loadString(key: String) throws -> String? {
        guard let data = try load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
