import Foundation

/// A security (stock, ETF, mutual fund, etc.) referenced by holdings and
/// investment transactions. Plaid's `security_id` is global across
/// institutions — we just pass it through.
public struct Security: Identifiable, Sendable, Equatable, Codable {
    public var id: String { securityId }
    public let securityId: String
    public let tickerSymbol: String?
    public let name: String?
    public let type: String?
    public let closePrice: Double?
    public let currencyCode: String

    public init(
        securityId: String,
        tickerSymbol: String? = nil,
        name: String? = nil,
        type: String? = nil,
        closePrice: Double? = nil,
        currencyCode: String = "USD"
    ) {
        self.securityId = securityId
        self.tickerSymbol = tickerSymbol
        self.name = name
        self.type = type
        self.closePrice = closePrice
        self.currencyCode = currencyCode
    }
}
