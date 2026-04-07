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

    public func isModelLoaded() async -> Bool {
        if case .loaded = await modelManager.currentStatus { return true }
        return false
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
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

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

        case .budgetStatus(let category):
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
