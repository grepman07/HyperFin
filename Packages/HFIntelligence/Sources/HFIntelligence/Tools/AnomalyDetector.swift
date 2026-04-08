import Foundation
import HFDomain
import HFShared

public struct AnomalyDetector: Sendable {

    public init() {}

    /// Compares current period spending to a 3-month baseline average.
    /// A spike is detected when current exceeds 1.5x the baseline.
    public func detect(
        category: String?,
        period: DatePeriod,
        transactionRepo: TransactionRepository,
        categoryRepo: CategoryRepository
    ) async throws -> AnomalyResult {
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

        let now = Date()
        let calendar = Calendar.current

        // Current period spending
        let currentRange = period.dateRange
        let currentSpend = try await transactionRepo.spendingTotal(
            categoryId: categoryId, from: currentRange.start, to: currentRange.end
        )

        // Baseline: average of previous 3 months
        var baselineMonths: [Decimal] = []
        for i in 1...3 {
            let monthStart = calendar.date(byAdding: .month, value: -i, to: now.startOfMonth)!
            let monthEnd = calendar.date(byAdding: .month, value: -(i - 1), to: now.startOfMonth)!
            let monthSpend = try await transactionRepo.spendingTotal(
                categoryId: categoryId, from: monthStart, to: monthEnd
            )
            baselineMonths.append(monthSpend)
        }

        let baseline = baselineMonths.isEmpty ? Decimal.zero :
            baselineMonths.reduce(Decimal.zero, +) / Decimal(baselineMonths.count)

        let deltaPercent: Int
        if baseline > 0 {
            deltaPercent = Int(Double(truncating: ((currentSpend - baseline) / baseline) as NSDecimalNumber) * 100)
        } else {
            deltaPercent = currentSpend > 0 ? 100 : 0
        }

        let isSpike = baseline > 0 && currentSpend > baseline * Decimal(string: "1.5")!

        return AnomalyResult(
            isSpike: isSpike,
            baseline: baseline,
            current: currentSpend,
            deltaPercent: deltaPercent,
            categoryLabel: categoryLabel,
            periodLabel: period.humanLabel
        )
    }
}
