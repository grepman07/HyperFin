import Foundation
import LocalAuthentication
import HFShared

public enum BiometricType: Sendable {
    case faceID
    case touchID
    case none
}

public enum BiometricError: Error, Sendable {
    case notAvailable
    case authenticationFailed
    case userCancelled
    case biometryLockout
    case unknown(String)
}

public actor BiometricAuthManager {
    public init() {}

    public var availableBiometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        default: return .none
        }
    }

    public func authenticate(reason: String = "Unlock HyperFin") async throws -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            HFLogger.security.error("Biometric not available: \(error?.localizedDescription ?? "unknown")")
            throw BiometricError.notAvailable
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            HFLogger.security.info("Biometric authentication succeeded")
            return success
        } catch let authError as LAError {
            switch authError.code {
            case .userCancel:
                throw BiometricError.userCancelled
            case .biometryLockout:
                throw BiometricError.biometryLockout
            case .authenticationFailed:
                throw BiometricError.authenticationFailed
            default:
                throw BiometricError.unknown(authError.localizedDescription)
            }
        }
    }
}
