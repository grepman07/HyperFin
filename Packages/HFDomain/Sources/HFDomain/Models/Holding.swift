import Foundation

/// A current position in a single security on a single investment account.
/// Refreshed wholesale on each `/v1/investments/holdings` call — no history.
public struct Holding: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let accountId: String
    public let securityId: String
    public let quantity: Double
    public let institutionPrice: Double?
    public let institutionValue: Double?
    public let costBasis: Double?
    public let currencyCode: String

    public init(
        id: UUID = UUID(),
        accountId: String,
        securityId: String,
        quantity: Double,
        institutionPrice: Double? = nil,
        institutionValue: Double? = nil,
        costBasis: Double? = nil,
        currencyCode: String = "USD"
    ) {
        self.id = id
        self.accountId = accountId
        self.securityId = securityId
        self.quantity = quantity
        self.institutionPrice = institutionPrice
        self.institutionValue = institutionValue
        self.costBasis = costBasis
        self.currencyCode = currencyCode
    }

    /// Unrealized P/L vs cost basis (nil if either side is missing).
    public var unrealizedPL: Double? {
        guard let v = institutionValue, let c = costBasis else { return nil }
        return v - c
    }
}
