import Foundation

public enum AlertType: String, Codable, Sendable {
    case budgetThreshold
    case budgetExceeded
    case unusualTransaction
    case weeklySummary
    case billReminder
    case subscriptionPriceChange
}

public struct AlertConfig: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var alertType: AlertType
    public var isEnabled: Bool
    public var threshold: Decimal?
    public var preferredDay: Int?
    public var preferredHour: Int?

    public init(
        id: UUID = UUID(),
        alertType: AlertType,
        isEnabled: Bool = true,
        threshold: Decimal? = nil,
        preferredDay: Int? = nil,
        preferredHour: Int? = nil
    ) {
        self.id = id
        self.alertType = alertType
        self.isEnabled = isEnabled
        self.threshold = threshold
        self.preferredDay = preferredDay
        self.preferredHour = preferredHour
    }
}
