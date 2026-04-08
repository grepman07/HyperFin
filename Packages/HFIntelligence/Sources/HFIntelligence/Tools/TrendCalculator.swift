import Foundation
import HFDomain
import HFShared

public struct TrendCalculator: Sendable {

    public init() {}

    public func calculate(
        category: String?,
        months: Int,
        transactionRepo: TransactionRepository,
        categoryRepo: CategoryRepository
    ) async throws -> TrendResult {
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

        let calendar = Calendar.current
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"

        var monthlyTotals: [(String, Decimal)] = []

        for i in (0..<months).reversed() {
            let monthStart = calendar.date(byAdding: .month, value: -i, to: now.startOfMonth)!
            let monthEnd: Date
            if i == 0 {
                monthEnd = now
            } else {
                monthEnd = calendar.date(byAdding: .month, value: -(i - 1), to: now.startOfMonth)!
            }

            let spent = try await transactionRepo.spendingTotal(
                categoryId: categoryId, from: monthStart, to: monthEnd
            )
            monthlyTotals.append((formatter.string(from: monthStart), spent))
        }

        // Month-over-month growth rate (average)
        var growthRates: [Double] = []
        for i in 1..<monthlyTotals.count {
            let prev = monthlyTotals[i - 1].1
            let curr = monthlyTotals[i].1
            if prev > 0 {
                let rate = Double(truncating: ((curr - prev) / prev) as NSDecimalNumber) * 100
                growthRates.append(rate)
            }
        }
        let avgGrowth = growthRates.isEmpty ? 0 : growthRates.reduce(0, +) / Double(growthRates.count)

        // Projected annual: average monthly × 12
        let avgMonthly = monthlyTotals.isEmpty ? Decimal.zero :
            monthlyTotals.reduce(Decimal.zero) { $0 + $1.1 } / Decimal(monthlyTotals.count)
        let projectedAnnual = avgMonthly * 12

        return TrendResult(
            monthlyTotals: monthlyTotals,
            momGrowthRate: avgGrowth,
            projectedAnnual: projectedAnnual,
            categoryLabel: categoryLabel
        )
    }
}
