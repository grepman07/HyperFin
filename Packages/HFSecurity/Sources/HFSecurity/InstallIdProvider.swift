import Foundation
import HFShared

/// Provides a stable, random installation ID persisted in the Keychain so it
/// survives app updates (but NOT full device wipes / reinstalls that clear the
/// keychain). Used as the only identifier on telemetry events — no user ID,
/// no device ID, no email is ever sent to the server.
public struct InstallIdProvider: Sendable {
    private let keychain: KeychainManager
    private let key: String

    public init(
        keychain: KeychainManager = KeychainManager(),
        key: String = "com.hyperfin.installId"
    ) {
        self.keychain = keychain
        self.key = key
    }

    /// Return the existing install ID or generate + persist a new one.
    /// If the keychain read fails unexpectedly, a new UUID is still returned
    /// (and persistence is best-effort) so telemetry never blocks on keychain.
    public func currentInstallId() -> String {
        if let existing = try? keychain.loadString(key: key), !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        try? keychain.saveString(key: key, value: newId)
        HFLogger.security.info("InstallIdProvider: created new install ID")
        return newId
    }

    /// Remove the stored install ID. Only call when wiping all user data.
    public func reset() throws {
        try keychain.delete(key: key)
    }
}
