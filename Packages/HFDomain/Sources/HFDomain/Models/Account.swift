import Foundation

public enum AccountType: String, Codable, Sendable {
    case checking
    case savings
    case credit
    case loan
    case investment
}

public struct Account: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var plaidAccountId: String
    public var institutionName: String
    public var accountName: String
    public var accountType: AccountType
    public var currentBalance: Decimal
    public var availableBalance: Decimal?
    public var currencyCode: String
    public var lastSynced: Date?
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        plaidAccountId: String,
        institutionName: String,
        accountName: String,
        accountType: AccountType,
        currentBalance: Decimal,
        availableBalance: Decimal? = nil,
        currencyCode: String = "USD",
        lastSynced: Date? = nil,
        isActive: Bool = true
    ) {
        self.id = id
        self.plaidAccountId = plaidAccountId
        self.institutionName = institutionName
        self.accountName = accountName
        self.accountType = accountType
        self.currentBalance = currentBalance
        self.availableBalance = availableBalance
        self.currencyCode = currencyCode
        self.lastSynced = lastSynced
        self.isActive = isActive
    }
}
