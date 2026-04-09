import Foundation

public enum ChatTone: String, Sendable, Equatable, CaseIterable, Codable {
    case professional
    case friendly
    case funny
    case strict

    public var displayName: String {
        switch self {
        case .professional: "Professional"
        case .friendly: "Friendly"
        case .funny: "Funny"
        case .strict: "Strict"
        }
    }

    public var icon: String {
        switch self {
        case .professional: "briefcase.fill"
        case .friendly: "face.smiling"
        case .funny: "theatermasks.fill"
        case .strict: "exclamationmark.triangle.fill"
        }
    }
}

public struct UserProfile: Sendable, Equatable {
    public var displayName: String?
    public var monthlyIncome: Decimal?
    public var financialGoals: [String]
    public var onboardingCompleted: Bool
    public var preferredCurrency: String
    public var chatTone: ChatTone
    public var createdAt: Date
    /// Whether the user has opted into anonymized telemetry collection.
    /// Default is `false` — no telemetry is captured unless this is explicitly enabled.
    public var telemetryOptIn: Bool
    /// Timestamp of the most recent opt-in (used for audit/display in Settings).
    public var telemetryOptInDate: Date?

    public init(
        displayName: String? = nil,
        monthlyIncome: Decimal? = nil,
        financialGoals: [String] = [],
        onboardingCompleted: Bool = false,
        preferredCurrency: String = "USD",
        chatTone: ChatTone = .professional,
        createdAt: Date = Date(),
        telemetryOptIn: Bool = false,
        telemetryOptInDate: Date? = nil
    ) {
        self.displayName = displayName
        self.monthlyIncome = monthlyIncome
        self.financialGoals = financialGoals
        self.onboardingCompleted = onboardingCompleted
        self.preferredCurrency = preferredCurrency
        self.chatTone = chatTone
        self.createdAt = createdAt
        self.telemetryOptIn = telemetryOptIn
        self.telemetryOptInDate = telemetryOptInDate
    }
}
