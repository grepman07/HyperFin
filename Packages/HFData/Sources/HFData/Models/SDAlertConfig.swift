import Foundation
import SwiftData
import HFDomain

@Model
public final class SDAlertConfig {
    @Attribute(.unique) public var id: UUID
    public var alertTypeRaw: String
    public var isEnabled: Bool
    public var threshold: Decimal?
    public var preferredDay: Int?
    public var preferredHour: Int?

    public init(from domain: AlertConfig) {
        self.id = domain.id
        self.alertTypeRaw = domain.alertType.rawValue
        self.isEnabled = domain.isEnabled
        self.threshold = domain.threshold
        self.preferredDay = domain.preferredDay
        self.preferredHour = domain.preferredHour
    }

    public func toDomain() -> AlertConfig {
        AlertConfig(
            id: id,
            alertType: AlertType(rawValue: alertTypeRaw) ?? .weeklySummary,
            isEnabled: isEnabled,
            threshold: threshold,
            preferredDay: preferredDay,
            preferredHour: preferredHour
        )
    }
}
