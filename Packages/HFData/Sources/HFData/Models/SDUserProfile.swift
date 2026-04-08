import Foundation
import SwiftData
import HFDomain

@Model
public final class SDUserProfile {
    @Attribute(.unique) public var id: UUID
    public var monthlyIncome: Decimal?
    public var financialGoalsData: Data?
    public var onboardingCompleted: Bool
    public var preferredCurrency: String
    public var chatToneRaw: String = "professional"
    public var createdAt: Date

    public init(from domain: UserProfile) {
        self.id = UUID()
        self.monthlyIncome = domain.monthlyIncome
        self.financialGoalsData = try? JSONEncoder().encode(domain.financialGoals)
        self.onboardingCompleted = domain.onboardingCompleted
        self.preferredCurrency = domain.preferredCurrency
        self.chatToneRaw = domain.chatTone.rawValue
        self.createdAt = domain.createdAt
    }

    public func toDomain() -> UserProfile {
        let goals = (try? JSONDecoder().decode([String].self, from: financialGoalsData ?? Data())) ?? []
        return UserProfile(
            monthlyIncome: monthlyIncome,
            financialGoals: goals,
            onboardingCompleted: onboardingCompleted,
            preferredCurrency: preferredCurrency,
            chatTone: ChatTone(rawValue: chatToneRaw) ?? .professional,
            createdAt: createdAt
        )
    }
}
