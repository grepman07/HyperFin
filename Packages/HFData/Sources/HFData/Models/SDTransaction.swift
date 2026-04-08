import Foundation
import SwiftData
import HFDomain

@Model
public final class SDTransaction {
    @Attribute(.unique) public var id: UUID
    public var plaidTransactionId: String
    public var accountId: UUID
    public var amount: Decimal
    public var date: Date
    public var merchantName: String?
    public var originalDescription: String
    public var categoryId: UUID?
    public var isUserCategorized: Bool
    public var isPending: Bool
    public var notes: String?

    public var account: SDAccount?

    public init(from domain: Transaction) {
        self.id = domain.id
        self.plaidTransactionId = domain.plaidTransactionId
        self.accountId = domain.accountId
        self.amount = domain.amount
        self.date = domain.date
        self.merchantName = domain.merchantName
        self.originalDescription = domain.originalDescription
        self.categoryId = domain.categoryId
        self.isUserCategorized = domain.isUserCategorized
        self.isPending = domain.isPending
        self.notes = domain.notes
    }

    public func toDomain() -> Transaction {
        Transaction(
            id: id,
            plaidTransactionId: plaidTransactionId,
            accountId: accountId,
            amount: amount,
            date: date,
            merchantName: merchantName,
            originalDescription: originalDescription,
            categoryId: categoryId,
            isUserCategorized: isUserCategorized,
            isPending: isPending,
            notes: notes
        )
    }
}
