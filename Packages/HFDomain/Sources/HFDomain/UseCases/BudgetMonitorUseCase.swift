import Foundation

public struct BudgetAlert: Sendable {
    public let categoryId: UUID
    public let categoryName: String
    public let allocatedAmount: Decimal
    public let spentAmount: Decimal
    public let percentUsed: Double
    public let alertType: AlertType

    public init(categoryId: UUID, categoryName: String, allocatedAmount: Decimal, spentAmount: Decimal, percentUsed: Double, alertType: AlertType) {
        self.categoryId = categoryId
        self.categoryName = categoryName
        self.allocatedAmount = allocatedAmount
        self.spentAmount = spentAmount
        self.percentUsed = percentUsed
        self.alertType = alertType
    }
}

public struct BudgetMonitorUseCase: Sendable {
    private let budgetRepo: BudgetRepository
    private let transactionRepo: TransactionRepository
    private let categoryRepo: CategoryRepository

    public init(
        budgetRepo: BudgetRepository,
        transactionRepo: TransactionRepository,
        categoryRepo: CategoryRepository
    ) {
        self.budgetRepo = budgetRepo
        self.transactionRepo = transactionRepo
        self.categoryRepo = categoryRepo
    }

    public func checkThresholds() async throws -> [BudgetAlert] {
        let now = Date()
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: now)!.start

        guard let budget = try await budgetRepo.fetch(month: monthStart) else { return [] }
        let categories = try await categoryRepo.fetchAll()

        var alerts: [BudgetAlert] = []
        for line in budget.lines {
            let spent = try await transactionRepo.spendingTotal(
                categoryId: line.categoryId, from: monthStart, to: now
            )
            let percent = line.allocatedAmount > 0
                ? NSDecimalNumber(decimal: spent / line.allocatedAmount).doubleValue
                : 0

            let categoryName = categories.first { $0.id == line.categoryId }?.name ?? "Unknown"

            if percent >= 1.0 {
                alerts.append(BudgetAlert(
                    categoryId: line.categoryId, categoryName: categoryName,
                    allocatedAmount: line.allocatedAmount, spentAmount: spent,
                    percentUsed: percent, alertType: .budgetExceeded
                ))
            } else if percent >= 0.8 {
                alerts.append(BudgetAlert(
                    categoryId: line.categoryId, categoryName: categoryName,
                    allocatedAmount: line.allocatedAmount, spentAmount: spent,
                    percentUsed: percent, alertType: .budgetThreshold
                ))
            }
        }
        return alerts
    }
}
