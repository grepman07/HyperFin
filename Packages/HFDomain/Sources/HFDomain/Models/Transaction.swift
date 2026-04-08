import Foundation

public struct Transaction: Identifiable, Sendable, Equatable {
    public let id: UUID
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

    public init(
        id: UUID = UUID(),
        plaidTransactionId: String,
        accountId: UUID,
        amount: Decimal,
        date: Date,
        merchantName: String? = nil,
        originalDescription: String,
        categoryId: UUID? = nil,
        isUserCategorized: Bool = false,
        isPending: Bool = false,
        notes: String? = nil
    ) {
        self.id = id
        self.plaidTransactionId = plaidTransactionId
        self.accountId = accountId
        self.amount = amount
        self.date = date
        self.merchantName = merchantName
        self.originalDescription = originalDescription
        self.categoryId = categoryId
        self.isUserCategorized = isUserCategorized
        self.isPending = isPending
        self.notes = notes
    }

    public var isExpense: Bool { amount > 0 }
    public var isIncome: Bool { amount < 0 }
    public var absoluteAmount: Decimal { abs(amount) }
}
