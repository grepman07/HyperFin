import Foundation
import CryptoKit
import HFShared

public struct EncryptionService: Sendable {
    private let symmetricKey: SymmetricKey

    public init(derivedFrom keyData: Data) {
        let hkdfKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyData),
            salt: "com.hyperfin.encryption".data(using: .utf8)!,
            info: "aes-256-gcm".data(using: .utf8)!,
            outputByteCount: 32
        )
        self.symmetricKey = hkdfKey
    }

    public func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        guard let combined = sealedBox.combined else {
            throw SecureEnclaveError.encryptionFailed
        }
        return combined
    }

    public func decrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    public func encryptString(_ string: String) throws -> Data {
        guard let data = string.data(using: .utf8) else {
            throw SecureEnclaveError.encryptionFailed
        }
        return try encrypt(data)
    }

    public func decryptString(_ data: Data) throws -> String {
        let decrypted = try decrypt(data)
        guard let string = String(data: decrypted, encoding: .utf8) else {
            throw SecureEnclaveError.decryptionFailed
        }
        return string
    }
}
