import Foundation

public protocol ChatService: Sendable {
    func sendMessage(_ text: String, context: ChatContext) -> AsyncThrowingStream<String, Error>
    func isModelLoaded() async -> Bool
    func loadModel() async throws
}

public struct ChatContext: Sendable {
    public var sessionId: UUID
    public var recentMessages: [ChatMessage]
    public var userProfile: UserProfile?

    public init(
        sessionId: UUID,
        recentMessages: [ChatMessage] = [],
        userProfile: UserProfile? = nil
    ) {
        self.sessionId = sessionId
        self.recentMessages = recentMessages
        self.userProfile = userProfile
    }
}

public protocol TransactionCategorizer: Sendable {
    func categorize(_ transaction: Transaction) async throws -> UUID?
    func categorizeBatch(_ transactions: [Transaction]) async throws -> [UUID: UUID]
}

public protocol BudgetSuggestionService: Sendable {
    func generateBudget(from transactions: [Transaction], categories: [SpendingCategory]) async throws -> Budget
}

public enum ChatIntent: Sendable, Equatable {
    case spendingQuery(category: String?, merchant: String?, period: DatePeriod)
    case budgetStatus(category: String?)
    case accountBalance(accountName: String?)
    case transactionSearch(merchant: String?, minAmount: Decimal?, maxAmount: Decimal?)
    case generalAdvice(topic: String)
    case greeting
    case unknown(rawQuery: String)
}

public enum DatePeriod: Sendable, Equatable {
    case today
    case thisWeek
    case thisMonth
    case lastMonth
    case last30Days
    case last90Days
    case custom(from: Date, to: Date)

    public var dateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()
        switch self {
        case .today:
            return (calendar.startOfDay(for: now), now)
        case .thisWeek:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return (start, now)
        case .thisMonth:
            let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
            return (start, now)
        case .lastMonth:
            let lastMonth = calendar.date(byAdding: .month, value: -1, to: now)!
            let interval = calendar.dateInterval(of: .month, for: lastMonth)!
            return (interval.start, interval.end)
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -30, to: now)!, now)
        case .last90Days:
            return (calendar.date(byAdding: .day, value: -90, to: now)!, now)
        case .custom(let from, let to):
            return (from, to)
        }
    }
}
