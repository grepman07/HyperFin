import Foundation
import Security
import CryptoKit
import HFShared

public enum SecureEnclaveError: Error, Sendable {
    case keyGenerationFailed
    case keyNotFound
    case encryptionFailed
    case decryptionFailed
    case notSupported
    case unexpectedError(String)
}

public struct SecureEnclaveManager: Sendable {
    private let tag: String

    public init(tag: String = HFConstants.Security.secureEnclaveTag) {
        self.tag = tag
    }

    public static var isSupported: Bool {
        SecureEnclave.isAvailable
    }

    public func getOrCreateKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let existing = try loadKey() {
            return existing
        }
        return try generateKey()
    }

    private func generateKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable else {
            throw SecureEnclaveError.notSupported
        }

        let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            nil
        )!

        let key = try SecureEnclave.P256.Signing.PrivateKey(
            compactRepresentable: false,
            accessControl: accessControl
        )

        let keyData = key.dataRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.hyperfin.enclave",
            kSecAttrAccount as String: tag,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)

        HFLogger.security.info("Secure Enclave key generated")
        return key
    }

    private func loadKey() throws -> SecureEnclave.P256.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.hyperfin.enclave",
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try SecureEnclave.P256.Signing.PrivateKey(
            dataRepresentation: data
        )
    }

    public func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.hyperfin.enclave",
            kSecAttrAccount as String: tag,
        ]
        SecItemDelete(query as CFDictionary)
        HFLogger.security.info("Secure Enclave key deleted")
    }
}
