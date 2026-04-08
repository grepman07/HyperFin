import Foundation
import HFDomain
import HFShared

public struct ToolDispatcher: Sendable {
    private let spendAggregator = SpendAggregator()
    private let budgetComparator = BudgetComparator()
    private let anomalyDetector = AnomalyDetector()
    private let trendCalculator = TrendCalculator()

    public init() {}

    public func dispatch(
        intent: ChatIntent,
        transactionRepo: TransactionRepository,
        categoryRepo: CategoryRepository,
        accountRepo: AccountRepository,
        budgetRepo: BudgetRepository
    ) async throws -> any ToolResult {
        switch intent {
        case .spendingQuery(let category, let merchant, let period):
            return try await spendAggregator.aggregate(
                category: category, merchant: merchant, period: period,
                transactionRepo: transactionRepo, categoryRepo: categoryRepo
            )

        case .budgetStatus(let category):
            return try await budgetComparator.compare(
                category: category,
                transactionRepo: transactionRepo, categoryRepo: categoryRepo, budgetRepo: budgetRepo
            )

        case .accountBalance(let accountName):
            return try await handleAccountBalance(accountName: accountName, accountRepo: accountRepo)

        case .transactionSearch(let merchant, _, _):
            return try await handleTransactionSearch(merchant: merchant, transactionRepo: transactionRepo)

        case .trendQuery(let category, let months):
            return try await trendCalculator.calculate(
                category: category, months: months,
                transactionRepo: transactionRepo, categoryRepo: categoryRepo
            )

        case .anomalyCheck(let category, let period):
            return try await anomalyDetector.detect(
                category: category, period: period,
                transactionRepo: transactionRepo, categoryRepo: categoryRepo
            )

        case .generalAdvice:
            return PassthroughResult(
                message: "I can help with spending questions, budgets, account balances, spending trends, and transaction searches. What would you like to know?",
                intentType: "general_advice"
            )

        case .greeting:
            return PassthroughResult(
                message: "Hey! How can I help with your finances today?",
                intentType: "greeting"
            )

        case .unknown:
            return PassthroughResult(
                message: "I can help with spending, budgets, balances, trends, and transactions. Try asking something like \"How much did I spend on food this month?\"",
                intentType: "unknown"
            )
        }
    }

    // MARK: - Direct Handlers

    private func handleAccountBalance(accountName: String?, accountRepo: AccountRepository) async throws -> AccountBalanceResult {
        let accounts = try await accountRepo.fetchAll()

        if let name = accountName {
            let lowered = name.lowercased()
            let filtered = accounts.filter {
                $0.accountName.lowercased().contains(lowered) || $0.institutionName.lowercased().contains(lowered)
            }
            let total = filtered.reduce(Decimal.zero) { $0 + $1.currentBalance }
            return AccountBalanceResult(
                accounts: filtered.map { ($0.accountName, $0.institutionName, $0.currentBalance) },
                totalBalance: total
            )
        }

        let total = accounts.reduce(Decimal.zero) { $0 + $1.currentBalance }
        return AccountBalanceResult(
            accounts: accounts.map { ($0.accountName, $0.institutionName, $0.currentBalance) },
            totalBalance: total
        )
    }

    private func handleTransactionSearch(merchant: String?, transactionRepo: TransactionRepository) async throws -> TransactionSearchResult {
        guard let merchant else {
            return TransactionSearchResult(merchant: "", transactions: [], total: 0, count: 0)
        }

        let transactions = try await transactionRepo.searchByMerchant(merchant)
        let expenses = transactions.filter { $0.isExpense }
        let total = expenses.reduce(Decimal.zero) { $0 + $1.amount }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let recent = transactions.prefix(5).map { txn in
            (formatter.string(from: txn.date), txn.amount)
        }

        return TransactionSearchResult(
            merchant: merchant,
            transactions: recent,
            total: total,
            count: transactions.count
        )
    }
}
