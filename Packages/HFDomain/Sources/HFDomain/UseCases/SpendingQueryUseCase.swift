import Foundation

public struct SpendingQueryResult: Sendable {
    public let total: Decimal
    public let transactionCount: Int
    public let topMerchants: [(name: String, total: Decimal)]
    public let categoryName: String?
    public let period: DatePeriod

    public init(
        total: Decimal,
        transactionCount: Int,
        topMerchants: [(name: String, total: Decimal)],
        categoryName: String?,
        period: DatePeriod
    ) {
        self.total = total
        self.transactionCount = transactionCount
        self.topMerchants = topMerchants
        self.categoryName = categoryName
        self.period = period
    }
}

public struct SpendingQueryUseCase: Sendable {
    private let transactionRepo: TransactionRepository
    private let categoryRepo: CategoryRepository

    public init(transactionRepo: TransactionRepository, categoryRepo: CategoryRepository) {
        self.transactionRepo = transactionRepo
        self.categoryRepo = categoryRepo
    }

    public func execute(categoryName: String?, merchant: String?, period: DatePeriod) async throws -> SpendingQueryResult {
        let range = period.dateRange

        var categoryId: UUID?
        if let categoryName {
            let categories = try await categoryRepo.fetchAll()
            categoryId = categories.first { $0.name.localizedCaseInsensitiveContains(categoryName) }?.id
        }

        let transactions: [Transaction]
        if let merchant {
            transactions = try await transactionRepo.searchByMerchant(merchant)
                .filter { $0.date >= range.start && $0.date <= range.end }
        } else {
            transactions = try await transactionRepo.fetch(
                accountId: nil, categoryId: categoryId,
                from: range.start, to: range.end, limit: nil
            )
        }

        let expenses = transactions.filter { $0.isExpense }
        let total = expenses.reduce(Decimal.zero) { $0 + $1.amount }

        var merchantTotals: [String: Decimal] = [:]
        for txn in expenses {
            let name = txn.merchantName ?? "Unknown"
            merchantTotals[name, default: 0] += txn.amount
        }
        let topMerchants = merchantTotals.sorted { $0.value > $1.value }
            .prefix(5)
            .map { (name: $0.key, total: $0.value) }

        return SpendingQueryResult(
            total: total,
            transactionCount: expenses.count,
            topMerchants: topMerchants,
            categoryName: categoryName,
            period: period
        )
    }
}
