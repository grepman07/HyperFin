import Foundation

public struct ParsedReceipt: Codable, Sendable {
    public var merchantName: String?
    public var totalAmount: Decimal?
    public var date: Date?
    public var rawDateString: String?

    public init(
        merchantName: String? = nil,
        totalAmount: Decimal? = nil,
        date: Date? = nil,
        rawDateString: String? = nil
    ) {
        self.merchantName = merchantName
        self.totalAmount = totalAmount
        self.date = date
        self.rawDateString = rawDateString
    }

    public var isEmpty: Bool {
        merchantName == nil && totalAmount == nil && date == nil
    }
}
