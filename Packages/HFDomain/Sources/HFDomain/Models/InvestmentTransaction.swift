import Foundation

/// A single investment-account transaction: buy, sell, dividend, fee, etc.
/// Mirrors Plaid's `InvestmentTransaction`. Unlike cash transactions this
/// carries quantity + price since the activity can be share-based.
public struct InvestmentTransaction: Identifiable, Sendable, Equatable, Codable {
    public var id: String { investmentTransactionId }
    public let investmentTransactionId: String
    public let accountId: String
    public let securityId: String?
    public let date: Date
    public let name: String?
    /// Plaid's high-level type: `buy`, `sell`, `cash`, `fee`, `transfer`, `cancel`.
    public let type: String?
    /// Finer-grained variant: `dividend`, `buy`, `sell`, `contribution`, …
    public let subtype: String?
    public let quantity: Double?
    public let price: Double?
    public let fees: Double?
    public let amount: Double?
    public let currencyCode: String

    public init(
        investmentTransactionId: String,
        accountId: String,
        securityId: String? = nil,
        date: Date,
        name: String? = nil,
        type: String? = nil,
        subtype: String? = nil,
        quantity: Double? = nil,
        price: Double? = nil,
        fees: Double? = nil,
        amount: Double? = nil,
        currencyCode: String = "USD"
    ) {
        self.investmentTransactionId = investmentTransactionId
        self.accountId = accountId
        self.securityId = securityId
        self.date = date
        self.name = name
        self.type = type
        self.subtype = subtype
        self.quantity = quantity
        self.price = price
        self.fees = fees
        self.amount = amount
        self.currencyCode = currencyCode
    }
}
