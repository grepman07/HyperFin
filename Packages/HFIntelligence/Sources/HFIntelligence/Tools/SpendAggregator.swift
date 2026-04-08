import Foundation
import HFDomain
import HFShared

public struct SpendAggregator: Sendable {

    public init() {}

    public func aggregate(
        category: String?,
        merchant: String?,
        period: DatePeriod,
        transactionRepo: TransactionRepository,
        categoryRepo: CategoryRepository
    ) async throws -> SpendAggregateResult {
        let range = period.dateRange
        let categories = try await categoryRepo.fetchAll()

        var categoryId: UUID?
        var categoryLabel: String?

        if let category {
            if let matched = categories.first(where: { $0.name.localizedCaseInsensitiveContains(category) }) {
                categoryId = matched.id
                categoryLabel = matched.name
            } else {
                categoryLabel = category
            }
        }

        var transactions: [Transaction]

        if let merchant {
            transactions = try await transactionRepo.searchByMerchant(merchant)
            transactions = transactions.filter { $0.date >= range.start && $0.date <= range.end && $0.isExpense }
            categoryLabel = merchant
        } else {
            transactions = try await transactionRepo.fetch(
                accountId: nil, categoryId: categoryId, from: range.start, to: range.end, limit: 500
            )
            transactions = transactions.filter { $0.isExpense }
        }

        let total = transactions.reduce(Decimal.zero) { $0 + $1.amount }

        // Top merchants by spend
        var merchantTotals: [String: Decimal] = [:]
        for txn in transactions {
            let name = txn.merchantName ?? "Unknown"
            merchantTotals[name, default: 0] += txn.amount
        }
        let topMerchants = merchantTotals.sorted { $0.value > $1.value }
            .prefix(5)
            .map { ($0.key, $0.value) }

        return SpendAggregateResult(
            total: total,
            count: transactions.count,
            topMerchants: topMerchants,
            categoryLabel: categoryLabel,
            periodLabel: period.humanLabel
        )
    }
}
