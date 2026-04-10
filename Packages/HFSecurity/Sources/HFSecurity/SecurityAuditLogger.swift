import Foundation
import HFShared

/// Lightweight on-device audit logger for sensitive operations.
///
/// Uses the existing `HFLogger.security` OS Logger so events are visible in
/// Console.app / `log stream` but don't persist to a file or database.
/// The server-side `audit_log` table is the durable audit trail; this is the
/// complementary client-side diagnostic channel for debugging and QA.
///
/// Wire into: BiometricAuthManager, KeychainManager, PlaidLinkHandler,
/// and any other code path that touches credentials or financial data.
public enum SecurityAuditLogger {

    /// Log an access to a sensitive resource.
    ///
    /// Example:
    /// ```
    /// SecurityAuditLogger.logAccess(
    ///     action: "decrypt",
    ///     resource: "plaid_access_token",
    ///     detail: "sync triggered by user"
    /// )
    /// ```
    public static func logAccess(action: String, resource: String, detail: String? = nil) {
        let suffix = detail.map { " | \($0)" } ?? ""
        HFLogger.security.info("AUDIT: \(action) | resource=\(resource)\(suffix)")
    }

    /// Log an authentication event (biometric, passcode, token refresh, etc.).
    public static func logAuthEvent(_ event: String) {
        HFLogger.security.info("AUTH: \(event)")
    }

    /// Log a data-protection event (file protection applied, keychain write, etc.).
    public static func logDataProtection(_ event: String) {
        HFLogger.security.info("DATA_PROTECTION: \(event)")
    }
}
