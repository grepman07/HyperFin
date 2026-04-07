import Foundation
import HFDomain
import HFShared

public actor ChatEngine {
    private let inferenceEngine: InferenceEngine
    private let modelManager: ModelManager
    private let intentParser: IntentParser
    private let promptAssembler: PromptAssembler

    private var transactionRepo: TransactionRepository?
    private var categoryRepo: CategoryRepository?
    private var accountRepo: AccountRepository?
    private var budgetRepo: BudgetRepository?

    public init(
        inferenceEngine: InferenceEngine,
        modelManager: ModelManager
    ) {
        self.inferenceEngine = inferenceEngine
        self.modelManager = modelManager
        self.intentParser = IntentParser()
        self.promptAssembler = PromptAssembler()
    }

    public func setRepositories(
        transactions: TransactionRepository,
        categories: CategoryRepository,
        accounts: AccountRepository,
        budgets: BudgetRepository
    ) {
        self.transactionRepo = transactions
        self.categoryRepo = categories
        self.accountRepo = accounts
        self.budgetRepo = budgets
    }

    public var isModelAvailable: Bool {
        get async { await modelManager.isLoaded }
    }

    public var modelStatus: ModelStatus {
        get async { await modelManager.currentStatus }
    }

    public func loadModel() async throws {
        try await modelManager.loadModel()
    }

    public func sendMessage(_ text: String, context: ChatContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let intent = intentParser.parse(text)
                    HFLogger.ai.info("Parsed intent: \(String(describing: intent))")

                    let financialContext = try await gatherContext(for: intent)

                    // If model is loaded, use AI inference
                    if await modelManager.isLoaded {
                        let prompt = promptAssembler.assemble(
                            userQuery: text,
                            intent: intent,
                            financialContext: financialContext,
                            conversationHistory: context.recentMessages
                        )

                        let request = InferenceRequest(prompt: prompt)
                        for try await token in await inferenceEngine.generate(request) {
                            continuation.yield(token)
                        }
                    } else {
                        // Fallback: generate template response from structured data
                        let response = generateTemplateResponse(intent: intent, context: financialContext)
                        continuation.yield(response)
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Template Response (fallback when model not loaded)

    private func generateTemplateResponse(intent: ChatIntent, context: FinancialContext) -> String {
        switch intent {
        case .spendingQuery(let category, let merchant, let period):
            let label = merchant ?? category ?? "total"
            let periodLabel = periodString(period)
            if let total = context.totalSpending {
                let count = context.relevantTransactions.count
                var response = "You spent \(total.currencyFormatted) on \(label) \(periodLabel) across \(count) transaction\(count == 1 ? "" : "s")."
                let topMerchants = merchantSummary(context.relevantTransactions)
                if !topMerchants.isEmpty {
                    response += "\n\nTop merchants: \(topMerchants)"
                }
                return response
            }
            return "I don't have enough data to answer that yet."

        case .budgetStatus(let category):
            if let budget = context.currentBudget {
                let total = budget.totalAllocated
                let spent = budget.totalSpent
                let pct = total > 0 ? Int(Double(truncating: (spent / total) as NSDecimalNumber) * 100) : 0
                if let category {
                    return "Your \(category) budget: \(spent.currencyFormatted) of \(total.currencyFormatted) (\(pct)% used)."
                }
                return "Monthly budget: \(spent.currencyFormatted) spent of \(total.currencyFormatted) (\(pct)% used)."
            }
            return "You don't have a budget set up for this month."

        case .accountBalance:
            if let balance = context.totalBalance {
                var response = "Total balance: \(balance.currencyFormatted)"
                for account in context.accounts {
                    response += "\n- \(account.accountName): \(account.currentBalance.currencyFormatted)"
                }
                return response
            }
            return "No accounts linked yet."

        case .transactionSearch(let merchant, _, _):
            let count = context.relevantTransactions.count
            if count > 0 {
                return "Found \(count) transaction\(count == 1 ? "" : "s") from \(merchant ?? "that search")."
            }
            return "No matching transactions found."

        case .generalAdvice:
            return "I can help with spending questions, budgets, account balances, and transaction searches. What would you like to know?"

        case .greeting:
            return "Hey! How can I help with your finances today?"

        case .unknown:
            return "I can help with spending, budgets, balances, and transactions. Try asking something like \"How much did I spend on food this month?\""
        }
    }

    private func periodString(_ period: DatePeriod) -> String {
        switch period {
        case .today: "today"
        case .thisWeek: "this week"
        case .thisMonth: "this month"
        case .lastMonth: "last month"
        case .last30Days: "in the last 30 days"
        case .last90Days: "in the last 90 days"
        case .custom: "in that period"
        }
    }

    private func merchantSummary(_ transactions: [Transaction]) -> String {
        var totals: [String: Decimal] = [:]
        for txn in transactions where txn.isExpense {
            let name = txn.merchantName ?? "Unknown"
            totals[name, default: 0] += txn.amount
        }
        return totals.sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key): \($0.value.currencyFormatted)" }
            .joined(separator: ", ")
    }

    // MARK: - Context Gathering

    private func gatherContext(for intent: ChatIntent) async throws -> FinancialContext {
        var context = FinancialContext()

        guard let transactionRepo, let categoryRepo, let accountRepo, let budgetRepo else {
            return context
        }

        switch intent {
        case .spendingQuery(let category, let merchant, let period):
            let range = period.dateRange
            if let merchant {
                context.relevantTransactions = try await transactionRepo.searchByMerchant(merchant)
                    .filter { $0.date >= range.start && $0.date <= range.end }
            } else {
                let categories = try await categoryRepo.fetchAll()
                var categoryId: UUID?
                if let category {
                    categoryId = categories.first { $0.name.localizedCaseInsensitiveContains(category) }?.id
                }
                context.relevantTransactions = try await transactionRepo.fetch(
                    accountId: nil, categoryId: categoryId, from: range.start, to: range.end, limit: 50
                )
            }
            context.totalSpending = context.relevantTransactions
                .filter { $0.isExpense }
                .reduce(Decimal.zero) { $0 + $1.amount }

        case .budgetStatus:
            let now = Date()
            let monthStart = Calendar.current.dateInterval(of: .month, for: now)!.start
            context.currentBudget = try await budgetRepo.fetch(month: monthStart)
            context.categories = try await categoryRepo.fetchAll()

        case .accountBalance:
            context.accounts = try await accountRepo.fetchAll()
            context.totalBalance = try await accountRepo.totalBalance()

        case .transactionSearch(let merchant, _, _):
            if let merchant {
                context.relevantTransactions = try await transactionRepo.searchByMerchant(merchant)
            }

        case .generalAdvice, .greeting, .unknown:
            break
        }

        return context
    }
}

public struct FinancialContext: Sendable {
    public var relevantTransactions: [Transaction] = []
    public var totalSpending: Decimal?
    public var currentBudget: Budget?
    public var categories: [SpendingCategory] = []
    public var accounts: [Account] = []
    public var totalBalance: Decimal?
}
