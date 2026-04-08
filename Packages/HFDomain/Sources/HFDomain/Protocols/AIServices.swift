import Foundation
import HFShared

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

// MARK: - Chat Intent

public enum ChatIntent: Sendable, Equatable {
    case spendingQuery(category: String?, merchant: String?, period: DatePeriod)
    case budgetStatus(category: String?)
    case accountBalance(accountName: String?)
    case transactionSearch(merchant: String?, minAmount: Decimal?, maxAmount: Decimal?)
    case trendQuery(category: String?, months: Int)
    case anomalyCheck(category: String?, period: DatePeriod)
    case generalAdvice(topic: String)
    case greeting
    case unknown(rawQuery: String)
}

// MARK: - Date Period

public enum DatePeriod: Sendable, Equatable {
    case today
    case thisWeek
    case thisMonth
    case lastMonth
    case last30Days
    case last90Days
    case lastNMonths(Int)
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
        case .lastNMonths(let n):
            return (calendar.date(byAdding: .month, value: -n, to: now)!, now)
        case .custom(let from, let to):
            return (from, to)
        }
    }

    public var humanLabel: String {
        switch self {
        case .today: "today"
        case .thisWeek: "this week"
        case .thisMonth: "this month"
        case .lastMonth: "last month"
        case .last30Days: "the last 30 days"
        case .last90Days: "the last 90 days"
        case .lastNMonths(let n): "the last \(n) months"
        case .custom: "that period"
        }
    }
}

// MARK: - Tool Result Protocol

public protocol ToolResult: Sendable {
    var toolName: String { get }
    func toJSON() -> String
    func templateResponse() -> String
}

// MARK: - Concrete Tool Results

public struct SpendAggregateResult: ToolResult, Sendable {
    public let total: Decimal
    public let count: Int
    public let topMerchants: [(name: String, amount: Decimal)]
    public let categoryLabel: String?
    public let periodLabel: String

    public var toolName: String { "spend_aggregator" }

    public init(total: Decimal, count: Int, topMerchants: [(String, Decimal)], categoryLabel: String?, periodLabel: String) {
        self.total = total
        self.count = count
        self.topMerchants = topMerchants
        self.categoryLabel = categoryLabel
        self.periodLabel = periodLabel
    }

    public func toJSON() -> String {
        var merchants = "["
        merchants += topMerchants.prefix(5).map { "{\"name\":\"\($0.name)\",\"amount\":\($0.amount)}" }.joined(separator: ",")
        merchants += "]"
        return "{\"total\":\(total),\"count\":\(count),\"category\":\(categoryLabel.map { "\"\($0)\"" } ?? "null"),\"period\":\"\(periodLabel)\",\"top_merchants\":\(merchants)}"
    }

    public func templateResponse() -> String {
        let label = categoryLabel ?? "total"
        var response = "You spent \(total.currencyFormatted) on \(label) \(periodLabel) across \(count) transaction\(count == 1 ? "" : "s")."
        if topMerchants.count > 1 {
            let merchantList = topMerchants.prefix(3).map { "\($0.name): \($0.amount.currencyFormatted)" }.joined(separator: ", ")
            response += "\n\nTop merchants: \(merchantList)"
        }
        return response
    }
}

public struct BudgetCompareResult: ToolResult, Sendable {
    public let actual: Decimal
    public let budget: Decimal
    public let delta: Decimal
    public let percentUsed: Int
    public let isOver: Bool
    public let categoryLabel: String?
    public let periodLabel: String
    public let overBudgetCategories: [(name: String, spent: Decimal, allocated: Decimal)]
    public let nearLimitCategories: [(name: String, percentUsed: Int)]

    public var toolName: String { "budget_comparator" }

    public init(actual: Decimal, budget: Decimal, delta: Decimal, percentUsed: Int, isOver: Bool,
                categoryLabel: String?, periodLabel: String,
                overBudgetCategories: [(String, Decimal, Decimal)] = [],
                nearLimitCategories: [(String, Int)] = []) {
        self.actual = actual
        self.budget = budget
        self.delta = delta
        self.percentUsed = percentUsed
        self.isOver = isOver
        self.categoryLabel = categoryLabel
        self.periodLabel = periodLabel
        self.overBudgetCategories = overBudgetCategories
        self.nearLimitCategories = nearLimitCategories
    }

    public func toJSON() -> String {
        var over = "["
        over += overBudgetCategories.map { "{\"name\":\"\($0.name)\",\"spent\":\($0.spent),\"allocated\":\($0.allocated)}" }.joined(separator: ",")
        over += "]"
        var near = "["
        near += nearLimitCategories.map { "{\"name\":\"\($0.name)\",\"percent\":\($0.percentUsed)}" }.joined(separator: ",")
        near += "]"
        return "{\"actual\":\(actual),\"budget\":\(budget),\"delta\":\(delta),\"percent_used\":\(percentUsed),\"is_over\":\(isOver),\"category\":\(categoryLabel.map { "\"\($0)\"" } ?? "null"),\"period\":\"\(periodLabel)\",\"over_budget\":\(over),\"near_limit\":\(near)}"
    }

    public func templateResponse() -> String {
        if let cat = categoryLabel {
            let remaining = budget - actual
            return "\(cat) budget: \(actual.currencyFormatted) spent of \(budget.currencyFormatted) (\(percentUsed)%).\n\nYou have \(remaining.currencyFormatted) remaining this month."
        }
        var response = "Monthly Budget Overview\n\nSpent: \(actual.currencyFormatted) of \(budget.currencyFormatted) (\(percentUsed)%)"
        if !overBudgetCategories.isEmpty {
            response += "\n\nOver budget:"
            for cat in overBudgetCategories {
                response += "\n- \(cat.name): \(cat.spent.currencyFormatted) / \(cat.allocated.currencyFormatted)"
            }
        }
        if !nearLimitCategories.isEmpty {
            response += "\n\nApproaching limit:"
            for cat in nearLimitCategories {
                response += "\n- \(cat.name): \(cat.percentUsed)% used"
            }
        }
        return response
    }
}

public struct AnomalyResult: ToolResult, Sendable {
    public let isSpike: Bool
    public let baseline: Decimal
    public let current: Decimal
    public let deltaPercent: Int
    public let categoryLabel: String?
    public let periodLabel: String

    public var toolName: String { "anomaly_detector" }

    public init(isSpike: Bool, baseline: Decimal, current: Decimal, deltaPercent: Int, categoryLabel: String?, periodLabel: String) {
        self.isSpike = isSpike
        self.baseline = baseline
        self.current = current
        self.deltaPercent = deltaPercent
        self.categoryLabel = categoryLabel
        self.periodLabel = periodLabel
    }

    public func toJSON() -> String {
        "{\"is_spike\":\(isSpike),\"baseline\":\(baseline),\"current\":\(current),\"delta_percent\":\(deltaPercent),\"category\":\(categoryLabel.map { "\"\($0)\"" } ?? "null"),\"period\":\"\(periodLabel)\"}"
    }

    public func templateResponse() -> String {
        let label = categoryLabel ?? "overall spending"
        if isSpike {
            return "Spending spike detected for \(label) \(periodLabel). Current: \(current.currencyFormatted) vs. your 3-month average of \(baseline.currencyFormatted) (+\(deltaPercent)%)."
        }
        return "No unusual spending detected for \(label) \(periodLabel). Current: \(current.currencyFormatted), 3-month average: \(baseline.currencyFormatted)."
    }
}

public struct TrendResult: ToolResult, Sendable {
    public let monthlyTotals: [(month: String, amount: Decimal)]
    public let momGrowthRate: Double
    public let projectedAnnual: Decimal
    public let categoryLabel: String?

    public var toolName: String { "trend_calculator" }

    public init(monthlyTotals: [(String, Decimal)], momGrowthRate: Double, projectedAnnual: Decimal, categoryLabel: String?) {
        self.monthlyTotals = monthlyTotals
        self.momGrowthRate = momGrowthRate
        self.projectedAnnual = projectedAnnual
        self.categoryLabel = categoryLabel
    }

    public func toJSON() -> String {
        var months = "["
        months += monthlyTotals.map { "{\"month\":\"\($0.month)\",\"amount\":\($0.amount)}" }.joined(separator: ",")
        months += "]"
        return "{\"monthly_totals\":\(months),\"mom_growth_rate\":\(String(format: "%.1f", momGrowthRate)),\"projected_annual\":\(projectedAnnual),\"category\":\(categoryLabel.map { "\"\($0)\"" } ?? "null")}"
    }

    public func templateResponse() -> String {
        let label = categoryLabel ?? "total spending"
        var response = "Spending trend for \(label):\n"
        for entry in monthlyTotals {
            response += "\n- \(entry.month): \(entry.amount.currencyFormatted)"
        }
        let direction = momGrowthRate > 0 ? "up" : "down"
        let absGrowth = Swift.abs(momGrowthRate)
        response += "\n\nMonth-over-month: \(direction) \(String(format: "%.1f", absGrowth))%"
        let projFormatted = projectedAnnual.currencyFormatted
        response += "\nProjected annual: \(projFormatted)"
        return response
    }
}

public struct AccountBalanceResult: ToolResult, Sendable {
    public let accounts: [(name: String, institution: String, balance: Decimal)]
    public let totalBalance: Decimal

    public var toolName: String { "account_balance" }

    public init(accounts: [(String, String, Decimal)], totalBalance: Decimal) {
        self.accounts = accounts
        self.totalBalance = totalBalance
    }

    public func toJSON() -> String {
        var accs = "["
        accs += accounts.map { "{\"name\":\"\($0.name)\",\"institution\":\"\($0.institution)\",\"balance\":\($0.balance)}" }.joined(separator: ",")
        accs += "]"
        return "{\"accounts\":\(accs),\"total_balance\":\(totalBalance)}"
    }

    public func templateResponse() -> String {
        if accounts.isEmpty {
            return "No accounts linked yet. Connect a bank account to see your balances."
        }
        var response = "Total across all accounts: \(totalBalance.currencyFormatted)"
        for acc in accounts {
            response += "\n- \(acc.name) (\(acc.institution)): \(acc.balance.currencyFormatted)"
        }
        return response
    }
}

public struct TransactionSearchResult: ToolResult, Sendable {
    public let merchant: String
    public let transactions: [(date: String, amount: Decimal)]
    public let total: Decimal
    public let count: Int

    public var toolName: String { "transaction_search" }

    public init(merchant: String, transactions: [(String, Decimal)], total: Decimal, count: Int) {
        self.merchant = merchant
        self.transactions = transactions
        self.total = total
        self.count = count
    }

    public func toJSON() -> String {
        var txns = "["
        txns += transactions.prefix(5).map { "{\"date\":\"\($0.date)\",\"amount\":\($0.amount)}" }.joined(separator: ",")
        txns += "]"
        return "{\"merchant\":\"\(merchant)\",\"total\":\(total),\"count\":\(count),\"recent_transactions\":\(txns)}"
    }

    public func templateResponse() -> String {
        if count == 0 {
            return "No transactions found from \"\(merchant)\"."
        }
        var response = "Found \(count) transaction\(count == 1 ? "" : "s") from \(merchant) (total: \(total.currencyFormatted)).\n\nRecent:"
        for txn in transactions.prefix(5) {
            let negated = -txn.amount
            let amt = txn.amount < 0 ? "+\(negated.currencyFormatted)" : txn.amount.currencyFormatted
            response += "\n- \(txn.date): \(amt)"
        }
        if count > 5 {
            response += "\n\n...and \(count - 5) more."
        }
        return response
    }
}

public struct PassthroughResult: ToolResult, Sendable {
    public let message: String
    public let intentType: String

    public var toolName: String { "passthrough" }

    public init(message: String, intentType: String) {
        self.message = message
        self.intentType = intentType
    }

    public func toJSON() -> String {
        "{\"type\":\"\(intentType)\",\"message\":\"\(message)\"}"
    }

    public func templateResponse() -> String {
        message
    }
}
