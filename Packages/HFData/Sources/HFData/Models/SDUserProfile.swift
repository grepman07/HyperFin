import Foundation
import SwiftData
import HFDomain

@Model
public final class SDUserProfile {
    @Attribute(.unique) public var id: UUID
    public var displayName: String?
    public var monthlyIncome: Decimal?
    public var financialGoalsData: Data?
    public var onboardingCompleted: Bool
    public var preferredCurrency: String
    public var chatToneRaw: String = "professional"
    public var createdAt: Date
    public var telemetryOptIn: Bool = false
    public var telemetryOptInDate: Date?

    public init(from domain: UserProfile) {
        self.id = UUID()
        self.displayName = domain.displayName
        self.monthlyIncome = domain.monthlyIncome
        self.financialGoalsData = try? JSONEncoder().encode(domain.financialGoals)
        self.onboardingCompleted = domain.onboardingCompleted
        self.preferredCurrency = domain.preferredCurrency
        self.chatToneRaw = domain.chatTone.rawValue
        self.createdAt = domain.createdAt
        self.telemetryOptIn = domain.telemetryOptIn
        self.telemetryOptInDate = domain.telemetryOptInDate
    }

    public func toDomain() -> UserProfile {
        let goals = (try? JSONDecoder().decode([String].self, from: financialGoalsData ?? Data())) ?? []
        return UserProfile(
            displayName: displayName,
            monthlyIncome: monthlyIncome,
            financialGoals: goals,
            onboardingCompleted: onboardingCompleted,
            preferredCurrency: preferredCurrency,
            chatTone: ChatTone(rawValue: chatToneRaw) ?? .professional,
            createdAt: createdAt,
            telemetryOptIn: telemetryOptIn,
            telemetryOptInDate: telemetryOptInDate
        )
    }
}
