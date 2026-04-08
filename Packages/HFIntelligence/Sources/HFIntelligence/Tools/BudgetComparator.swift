import Foundation
import HFDomain
import HFShared

public struct BudgetComparator: Sendable {

    public init() {}

    public func compare(
        category: String?,
        transactionRepo: TransactionRepository,
        categoryRepo: CategoryRepository,
        budgetRepo: BudgetRepository
    ) async throws -> BudgetCompareResult {
        let now = Date()
        let monthStart = now.startOfMonth
        let categories = try await categoryRepo.fetchAll()

        guard let budget = try await budgetRepo.fetch(month: monthStart) else {
            return BudgetCompareResult(
                actual: 0, budget: 0, delta: 0, percentUsed: 0, isOver: false,
                categoryLabel: category, periodLabel: "this month"
            )
        }

        // Single category query
        if let category {
            let matched = categories.first { $0.name.localizedCaseInsensitiveContains(category) }
            if let catId = matched?.id, let line = budget.lines.first(where: { $0.categoryId == catId }) {
                let spent = try await transactionRepo.spendingTotal(categoryId: catId, from: monthStart, to: now)
                let pct = line.allocatedAmount > 0 ? Int(Double(truncating: (spent / line.allocatedAmount) as NSDecimalNumber) * 100) : 0
                let delta = spent - line.allocatedAmount
                return BudgetCompareResult(
                    actual: spent, budget: line.allocatedAmount, delta: delta, percentUsed: pct,
                    isOver: spent > line.allocatedAmount,
                    categoryLabel: matched?.name ?? category, periodLabel: "this month"
                )
            }
            return BudgetCompareResult(
                actual: 0, budget: 0, delta: 0, percentUsed: 0, isOver: false,
                categoryLabel: category, periodLabel: "this month"
            )
        }

        // Overall budget
        var totalAllocated: Decimal = 0
        var totalSpent: Decimal = 0
        var overBudget: [(String, Decimal, Decimal)] = []
        var nearLimit: [(String, Int)] = []

        for line in budget.lines {
            let spent = try await transactionRepo.spendingTotal(categoryId: line.categoryId, from: monthStart, to: now)
            totalAllocated += line.allocatedAmount
            totalSpent += spent

            let pct = line.allocatedAmount > 0 ? Int(Double(truncating: (spent / line.allocatedAmount) as NSDecimalNumber) * 100) : 0
            let catName = categories.first { $0.id == line.categoryId }?.name ?? "Unknown"

            if spent > line.allocatedAmount {
                overBudget.append((catName, spent, line.allocatedAmount))
            } else if pct >= 80 {
                nearLimit.append((catName, pct))
            }
        }

        let overallPct = totalAllocated > 0 ? Int(Double(truncating: (totalSpent / totalAllocated) as NSDecimalNumber) * 100) : 0

        return BudgetCompareResult(
            actual: totalSpent, budget: totalAllocated, delta: totalSpent - totalAllocated,
            percentUsed: overallPct, isOver: totalSpent > totalAllocated,
            categoryLabel: nil, periodLabel: "this month",
            overBudgetCategories: overBudget, nearLimitCategories: nearLimit
        )
    }
}
