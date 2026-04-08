import Foundation
import SwiftData
import HFDomain

@Model
public final class SDAccount {
    @Attribute(.unique) public var id: UUID
    public var plaidAccountId: String
    public var institutionName: String
    public var accountName: String
    public var accountTypeRaw: String
    public var currentBalance: Decimal
    public var availableBalance: Decimal?
    public var currencyCode: String
    public var lastSynced: Date?
    public var isActive: Bool

    @Relationship(deleteRule: .cascade, inverse: \SDTransaction.account)
    public var transactions: [SDTransaction] = []

    public init(from domain: Account) {
        self.id = domain.id
        self.plaidAccountId = domain.plaidAccountId
        self.institutionName = domain.institutionName
        self.accountName = domain.accountName
        self.accountTypeRaw = domain.accountType.rawValue
        self.currentBalance = domain.currentBalance
        self.availableBalance = domain.availableBalance
        self.currencyCode = domain.currencyCode
        self.lastSynced = domain.lastSynced
        self.isActive = domain.isActive
    }

    public func toDomain() -> Account {
        Account(
            id: id,
            plaidAccountId: plaidAccountId,
            institutionName: institutionName,
            accountName: accountName,
            accountType: AccountType(rawValue: accountTypeRaw) ?? .checking,
            currentBalance: currentBalance,
            availableBalance: availableBalance,
            currencyCode: currencyCode,
            lastSynced: lastSynced,
            isActive: isActive
        )
    }
}
