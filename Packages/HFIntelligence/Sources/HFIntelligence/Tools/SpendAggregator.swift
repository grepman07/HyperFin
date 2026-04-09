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

        HFLogger.ai.info("SpendAggregator: category=\(category ?? "nil"), merchant=\(merchant ?? "nil"), period=\(period.humanLabel), range=\(range.start)..\(range.end), categories_in_db=\(categories.count)")

        var categoryId: UUID?
        var categoryLabel: String?

        if let category {
            if let matched = categories.first(where: { $0.name.localizedCaseInsensitiveContains(category) }) {
                categoryId = matched.id
                categoryLabel = matched.name
                HFLogger.ai.info("SpendAggregator: matched category '\(matched.name)' id=\(matched.id.uuidString.prefix(8))")
            } else {
                categoryLabel = category
                let availableNames = categories.map { $0.name }.joined(separator: ", ")
                HFLogger.ai.warning("SpendAggregator: no category match for '\(category)'. Available: \(availableNames)")
            }
        }

        var transactions: [Transaction]

        if let merchant {
            transactions = try await transactionRepo.searchByMerchant(merchant)
            let beforeFilter = transactions.count
            transactions = transactions.filter { $0.date >= range.start && $0.date <= range.end && $0.isExpense }
            HFLogger.ai.info("SpendAggregator: merchant search for '\(merchant)' found \(beforeFilter) txns, \(transactions.count) after date+expense filter")
            categoryLabel = merchant
        } else {
            // FIX: pass limit=nil so we don't cap at 500 before client-side filter
            transactions = try await transactionRepo.fetch(
                accountId: nil, categoryId: categoryId, from: range.start, to: range.end, limit: nil
            )
            let beforeExpenseFilter = transactions.count
            transactions = transactions.filter { $0.isExpense }
            HFLogger.ai.info("SpendAggregator: category fetch returned \(beforeExpenseFilter) txns, \(transactions.count) expenses")
        }

        let total = transactions.reduce(Decimal.zero) { $0 + $1.amount }
        HFLogger.ai.info("SpendAggregator: total=\(total), count=\(transactions.count)")

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
