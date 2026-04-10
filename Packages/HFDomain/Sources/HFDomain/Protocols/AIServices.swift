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
    /// Generate a deterministic, tone-aware template response. Used when the
    /// LLM is unavailable or as a fallback. Callers should pass the user's
    /// preferred ChatTone so the wording matches their expectation.
    func templateResponse(tone: ChatTone) -> String
    /// Convenience overload — defaults to `.professional`.
    func templateResponse() -> String
}

public extension ToolResult {
    func templateResponse() -> String {
        templateResponse(tone: .professional)
    }
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
        // Dollar amounts are pre-formatted into human-readable strings so the
        // model only has to echo them verbatim. This avoids the small-model
        // failure mode of echoing a "$X,XXX.XX" template hint from the system
        // prompt.
        var merchants = "["
        merchants += topMerchants.prefix(5)
            .map { "{\"name\":\"\($0.name)\",\"amount\":\"\($0.amount.currencyFormatted)\"}" }
            .joined(separator: ",")
        merchants += "]"
        return "{\"total\":\"\(total.currencyFormatted)\",\"count\":\(count),\"category\":\(categoryLabel.map { "\"\($0)\"" } ?? "null"),\"period\":\"\(periodLabel)\",\"top_merchants\":\(merchants)}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        let label = categoryLabel ?? "total"
        let txnWord = count == 1 ? "transaction" : "transactions"
        let merchantSuffix: String = {
            guard topMerchants.count > 1 else { return "" }
            let list = topMerchants.prefix(3).map { "\($0.name): \($0.amount.currencyFormatted)" }.joined(separator: ", ")
            return "\n\nTop merchants: \(list)"
        }()

        switch tone {
        case .professional:
            return "You spent \(total.currencyFormatted) on \(label) \(periodLabel) across \(count) \(txnWord).\(merchantSuffix)"
        case .friendly:
            return "Looks like you spent \(total.currencyFormatted) on \(label) \(periodLabel) across \(count) \(txnWord) — not bad!\(merchantSuffix)"
        case .funny:
            if total > 0 {
                return "Whoa, \(total.currencyFormatted) on \(label) \(periodLabel)? Your wallet might need a wellness check! That's \(count) \(txnWord).\(merchantSuffix)"
            }
            return "Zero dollars on \(label) \(periodLabel)? Either you're incredibly disciplined or you forgot your wallet at home."
        case .strict:
            return "You spent \(total.currencyFormatted) on \(label) \(periodLabel) across \(count) \(txnWord). Review whether this aligns with your financial goals.\(merchantSuffix)"
        }
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
        over += overBudgetCategories
            .map { "{\"name\":\"\($0.name)\",\"spent\":\"\($0.spent.currencyFormatted)\",\"allocated\":\"\($0.allocated.currencyFormatted)\"}" }
            .joined(separator: ",")
        over += "]"
        var near = "["
        near += nearLimitCategories.map { "{\"name\":\"\($0.name)\",\"percent\":\($0.percentUsed)}" }.joined(separator: ",")
        near += "]"
        return "{\"actual\":\"\(actual.currencyFormatted)\",\"budget\":\"\(budget.currencyFormatted)\",\"delta\":\"\(delta.currencyFormatted)\",\"percent_used\":\(percentUsed),\"is_over\":\(isOver),\"category\":\(categoryLabel.map { "\"\($0)\"" } ?? "null"),\"period\":\"\(periodLabel)\",\"over_budget\":\(over),\"near_limit\":\(near)}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        let overUnderSuffix: String = {
            var parts = ""
            if !overBudgetCategories.isEmpty {
                parts += "\n\nOver budget:"
                for cat in overBudgetCategories {
                    parts += "\n- \(cat.name): \(cat.spent.currencyFormatted) / \(cat.allocated.currencyFormatted)"
                }
            }
            if !nearLimitCategories.isEmpty {
                parts += "\n\nApproaching limit:"
                for cat in nearLimitCategories {
                    parts += "\n- \(cat.name): \(cat.percentUsed)% used"
                }
            }
            return parts
        }()

        if let cat = categoryLabel {
            let remaining = budget - actual
            switch tone {
            case .professional:
                return "\(cat) budget: \(actual.currencyFormatted) spent of \(budget.currencyFormatted) (\(percentUsed)%). You have \(remaining.currencyFormatted) remaining."
            case .friendly:
                if isOver {
                    return "Heads up — you've gone a bit over on \(cat)! You've spent \(actual.currencyFormatted) out of \(budget.currencyFormatted). Maybe ease up a little?"
                }
                return "You're doing well on \(cat)! \(actual.currencyFormatted) spent of \(budget.currencyFormatted) — that leaves \(remaining.currencyFormatted) to go."
            case .funny:
                if isOver {
                    return "Your \(cat) budget called — it wants its money back! \(actual.currencyFormatted) spent vs. \(budget.currencyFormatted) budgeted. You're \((-delta).currencyFormatted) over. Oops!"
                }
                return "Good news: your \(cat) budget is still alive! \(actual.currencyFormatted) of \(budget.currencyFormatted) spent, with \(remaining.currencyFormatted) left to burn."
            case .strict:
                if isOver {
                    return "You have exceeded your \(cat) budget. Spent: \(actual.currencyFormatted) vs. \(budget.currencyFormatted) allocated. Overage: \((-delta).currencyFormatted). Immediate corrective action is recommended."
                }
                return "\(cat) budget: \(actual.currencyFormatted) of \(budget.currencyFormatted) (\(percentUsed)%). Remaining: \(remaining.currencyFormatted). Stay disciplined."
            }
        }

        switch tone {
        case .professional:
            return "Monthly Budget Overview\n\nSpent: \(actual.currencyFormatted) of \(budget.currencyFormatted) (\(percentUsed)%)\(overUnderSuffix)"
        case .friendly:
            return "Here's your budget snapshot! You've spent \(actual.currencyFormatted) out of \(budget.currencyFormatted) so far (\(percentUsed)%).\(overUnderSuffix)"
        case .funny:
            if isOver {
                return "Budget report card: C-minus. \(actual.currencyFormatted) spent vs. \(budget.currencyFormatted) planned. Your budget is giving you side-eye.\(overUnderSuffix)"
            }
            return "Budget check! \(actual.currencyFormatted) of \(budget.currencyFormatted) spent (\(percentUsed)%). Your wallet says thanks for not emptying it.\(overUnderSuffix)"
        case .strict:
            return "Budget Status: \(actual.currencyFormatted) of \(budget.currencyFormatted) (\(percentUsed)%). \(isOver ? "You are over budget. Reduce spending immediately." : "Within limits. Maintain discipline.")\(overUnderSuffix)"
        }
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
        "{\"is_spike\":\(isSpike),\"baseline\":\"\(baseline.currencyFormatted)\",\"current\":\"\(current.currencyFormatted)\",\"delta_percent\":\(deltaPercent),\"category\":\(categoryLabel.map { "\"\($0)\"" } ?? "null"),\"period\":\"\(periodLabel)\"}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        let label = categoryLabel ?? "overall spending"
        if isSpike {
            switch tone {
            case .professional:
                return "Spending spike detected for \(label) \(periodLabel). Current: \(current.currencyFormatted) vs. your 3-month average of \(baseline.currencyFormatted) (+\(deltaPercent)%)."
            case .friendly:
                return "Heads up — your \(label) is running higher than usual \(periodLabel)! You're at \(current.currencyFormatted) compared to a \(baseline.currencyFormatted) average. That's \(deltaPercent)% more than normal."
            case .funny:
                return "Yikes! Your \(label) \(periodLabel) just hit \(current.currencyFormatted) — that's \(deltaPercent)% above your \(baseline.currencyFormatted) average. Did you adopt a shopping hobby?"
            case .strict:
                return "Alert: \(label) spending is \(deltaPercent)% above baseline. Current: \(current.currencyFormatted) vs. average: \(baseline.currencyFormatted). Investigate and correct immediately."
            }
        }
        switch tone {
        case .professional:
            return "No unusual spending detected for \(label) \(periodLabel). Current: \(current.currencyFormatted), 3-month average: \(baseline.currencyFormatted)."
        case .friendly:
            return "All good on \(label) \(periodLabel)! You're at \(current.currencyFormatted), right in line with your \(baseline.currencyFormatted) average. Keep it up!"
        case .funny:
            return "Nothing weird going on with \(label) \(periodLabel) — \(current.currencyFormatted) vs. \(baseline.currencyFormatted) average. Boringly responsible. Love it."
        case .strict:
            return "No anomalies for \(label) \(periodLabel). Current: \(current.currencyFormatted), baseline: \(baseline.currencyFormatted). Continue monitoring."
        }
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
        months += monthlyTotals
            .map { "{\"month\":\"\($0.month)\",\"amount\":\"\($0.amount.currencyFormatted)\"}" }
            .joined(separator: ",")
        months += "]"
        return "{\"monthly_totals\":\(months),\"mom_growth_rate\":\(String(format: "%.1f", momGrowthRate)),\"projected_annual\":\"\(projectedAnnual.currencyFormatted)\",\"category\":\(categoryLabel.map { "\"\($0)\"" } ?? "null")}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        let label = categoryLabel ?? "total spending"
        let direction = momGrowthRate > 0 ? "up" : "down"
        let absGrowth = String(format: "%.1f", Swift.abs(momGrowthRate))
        let projFormatted = projectedAnnual.currencyFormatted

        var monthBreakdown = ""
        for entry in monthlyTotals {
            monthBreakdown += "\n- \(entry.month): \(entry.amount.currencyFormatted)"
        }

        switch tone {
        case .professional:
            return "Spending trend for \(label):\(monthBreakdown)\n\nMonth-over-month: \(direction) \(absGrowth)%\nProjected annual: \(projFormatted)"
        case .friendly:
            return "Here's how your \(label) has been trending:\(monthBreakdown)\n\nYou're trending \(direction) \(absGrowth)% month-over-month. At this pace, you're on track for about \(projFormatted) this year."
        case .funny:
            if momGrowthRate > 5 {
                return "Your \(label) is climbing faster than gas prices!\(monthBreakdown)\n\nThat's \(direction) \(absGrowth)% month-over-month. Annual projection: \(projFormatted). Might want to pump the brakes!"
            }
            return "Your \(label) trend report is in:\(monthBreakdown)\n\nTrending \(direction) \(absGrowth)% monthly. Projected annual: \(projFormatted). Your accountant would approve."
        case .strict:
            return "\(label) trend analysis:\(monthBreakdown)\n\nDirection: \(direction) \(absGrowth)% month-over-month. Projected annual: \(projFormatted). \(momGrowthRate > 0 ? "Evaluate whether this trajectory is sustainable." : "Downward trend noted. Maintain course.")"
        }
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
        accs += accounts
            .map { "{\"name\":\"\($0.name)\",\"institution\":\"\($0.institution)\",\"balance\":\"\($0.balance.currencyFormatted)\"}" }
            .joined(separator: ",")
        accs += "]"
        return "{\"accounts\":\(accs),\"total_balance\":\"\(totalBalance.currencyFormatted)\"}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        if accounts.isEmpty {
            switch tone {
            case .professional: return "No accounts linked yet. Connect a bank account to see your balances."
            case .friendly: return "Looks like you haven't linked any accounts yet! Once you do, I can show you your balances."
            case .funny: return "I'd love to tell you your balance, but there are no accounts linked. It's like checking the fridge when you haven't gone shopping!"
            case .strict: return "No accounts linked. Connect a bank account to proceed."
            }
        }
        var accountList = ""
        for acc in accounts {
            accountList += "\n- \(acc.name) (\(acc.institution)): \(acc.balance.currencyFormatted)"
        }
        switch tone {
        case .professional:
            return "Total across all accounts: \(totalBalance.currencyFormatted)\(accountList)"
        case .friendly:
            return "Here are your balances! Your total across all accounts is \(totalBalance.currencyFormatted).\(accountList)"
        case .funny:
            return "Drumroll please... your total balance is \(totalBalance.currencyFormatted)! Here's the breakdown:\(accountList)"
        case .strict:
            return "Account balances — Total: \(totalBalance.currencyFormatted)\(accountList)"
        }
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
        txns += transactions.prefix(5)
            .map { "{\"date\":\"\($0.date)\",\"amount\":\"\($0.amount.currencyFormatted)\"}" }
            .joined(separator: ",")
        txns += "]"
        return "{\"merchant\":\"\(merchant)\",\"total\":\"\(total.currencyFormatted)\",\"count\":\(count),\"recent_transactions\":\(txns)}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        if count == 0 {
            switch tone {
            case .professional: return "No transactions found from \"\(merchant)\"."
            case .friendly: return "I couldn't find any transactions from \(merchant). Maybe double-check the name?"
            case .funny: return "Zero transactions from \(merchant). Either you've never been there or they owe you a receipt!"
            case .strict: return "No transactions found from \"\(merchant)\". Verify the merchant name."
            }
        }
        let txnWord = count == 1 ? "transaction" : "transactions"
        var txnList = ""
        for txn in transactions.prefix(5) {
            let negated = -txn.amount
            let amt = txn.amount < 0 ? "+\(negated.currencyFormatted)" : txn.amount.currencyFormatted
            txnList += "\n- \(txn.date): \(amt)"
        }
        let moreSuffix = count > 5 ? "\n\n...and \(count - 5) more." : ""
        switch tone {
        case .professional:
            return "Found \(count) \(txnWord) from \(merchant) (total: \(total.currencyFormatted)).\n\nRecent:\(txnList)\(moreSuffix)"
        case .friendly:
            return "I found \(count) \(txnWord) from \(merchant) totaling \(total.currencyFormatted). Here are the recent ones:\(txnList)\(moreSuffix)"
        case .funny:
            return "You and \(merchant) have quite the relationship — \(count) \(txnWord) totaling \(total.currencyFormatted)!\(txnList)\(moreSuffix)"
        case .strict:
            return "\(count) \(txnWord) from \(merchant). Total: \(total.currencyFormatted).\(txnList)\(moreSuffix)"
        }
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

    public func templateResponse(tone: ChatTone) -> String {
        // Passthrough messages are pre-composed (greetings, advice, etc.)
        // and don't vary by tone — the upstream already wrote them.
        message
    }
}

// MARK: - LLM Intent Classification

/// Structured output from the LLM intent classifier
public struct ClassificationResult: Codable, Sendable {
    public let intent: String
    public let category: String?
    public let merchant: String?
    public let period: String?
    public let needsClarification: Bool
    public let clarification: String?

    enum CodingKeys: String, CodingKey {
        case intent, category, merchant, period
        case needsClarification = "needs_clarification"
        case clarification
    }

    public init(
        intent: String,
        category: String?,
        merchant: String?,
        period: String?,
        needsClarification: Bool,
        clarification: String?
    ) {
        self.intent = intent
        self.category = category
        self.merchant = merchant
        self.period = period
        self.needsClarification = needsClarification
        self.clarification = clarification
    }
}

/// Multi-turn conversation context — tracks slots across messages
public struct ConversationSlot: Sendable {
    public var lastIntent: String?
    public var lastCategory: String?
    public var lastMerchant: String?
    public var lastPeriod: DatePeriod?
    public var pendingClarification: Bool = false

    public init() {}

    public mutating func update(from classification: ClassificationResult) {
        if let cat = classification.category { lastCategory = cat }
        if let merchant = classification.merchant { lastMerchant = merchant }
        if let period = classification.period { lastPeriod = ConversationSlot.resolvePeriod(period) }
        lastIntent = classification.intent
        pendingClarification = classification.needsClarification
    }

    public mutating func updateFromRegex(_ intent: ChatIntent) {
        switch intent {
        case .spendingQuery(let cat, let merchant, let period):
            if let cat { lastCategory = cat }
            if let merchant { lastMerchant = merchant }
            lastPeriod = period
            lastIntent = "spending"
        case .trendQuery(let cat, _):
            if let cat { lastCategory = cat }
            lastIntent = "trend"
        case .budgetStatus(let cat):
            if let cat { lastCategory = cat }
            lastIntent = "budget"
        case .anomalyCheck(let cat, let period):
            if let cat { lastCategory = cat }
            lastPeriod = period
            lastIntent = "anomaly"
        case .greeting:
            clear()
        default: break
        }
        pendingClarification = false
    }

    public mutating func clear() {
        lastIntent = nil
        lastCategory = nil
        lastMerchant = nil
        lastPeriod = nil
        pendingClarification = false
    }

    private static func resolvePeriod(_ raw: String) -> DatePeriod {
        switch raw {
        case "today": return .today
        case "this_week": return .thisWeek
        case "this_month": return .thisMonth
        case "last_month": return .lastMonth
        case "last_30_days": return .last30Days
        case "last_90_days": return .last90Days
        default:
            // Handle "last_N_months" pattern
            if raw.hasPrefix("last_"), raw.hasSuffix("_months") {
                let middle = raw.dropFirst(5).dropLast(7)
                if let n = Int(middle) { return .lastNMonths(n) }
            }
            return .thisMonth
        }
    }
}
