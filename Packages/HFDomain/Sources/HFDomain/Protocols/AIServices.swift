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

    // MARK: - Wealth intents
    //
    // These answer questions about invested positions, loans/credit lines,
    // dividends/trades, and the combined "how rich am I" view. All are
    // read-only against the sync'd Plaid data on device.

    /// "What are my holdings?", "How much AAPL do I own?"
    /// `ticker` is an optional filter — ticker symbol or security name fragment.
    case holdingsQuery(ticker: String?)

    /// "What do I owe?", "Credit card balance?", "Mortgage?"
    /// `kind` is one of "credit" / "mortgage" / "student" or nil for all.
    case liabilityReport(kind: String?)

    /// "What's my net worth?" — cash accounts + holdings − liabilities.
    case netWorth

    /// "What dividends did I earn?", "Recent trades", "Investment fees".
    /// `activityType` filters to `dividend` / `buy` / `sell` / `fee` or nil.
    case investmentActivity(activityType: String?, period: DatePeriod)
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

// MARK: - Row-level retrieval results

/// One row returned by `list_transactions`. The date is pre-formatted so
/// the LLM copies it verbatim; amount stays Decimal so `currencyFormatted`
/// renders it identically to every other tool result.
public struct TransactionListRow: Sendable {
    public let date: String
    public let merchant: String
    public let amount: Decimal
    public let categoryName: String?

    public init(date: String, merchant: String, amount: Decimal, categoryName: String?) {
        self.date = date
        self.merchant = merchant
        self.amount = amount
        self.categoryName = categoryName
    }
}

public struct TransactionListResult: ToolResult, Sendable {
    public let rows: [TransactionListRow]
    public let total: Decimal
    /// Total number of matching transactions BEFORE truncation by `limit`.
    /// `rows.count` may be smaller; `truncated == true` when it is.
    public let count: Int
    public let periodLabel: String
    public let categoryLabel: String?
    public let merchantFilter: String?
    public let minAmount: Decimal?
    public let maxAmount: Decimal?
    public let limit: Int
    public let truncated: Bool

    public var toolName: String { "list_transactions" }

    public init(
        rows: [TransactionListRow],
        total: Decimal,
        count: Int,
        periodLabel: String,
        categoryLabel: String?,
        merchantFilter: String?,
        minAmount: Decimal?,
        maxAmount: Decimal?,
        limit: Int,
        truncated: Bool
    ) {
        self.rows = rows
        self.total = total
        self.count = count
        self.periodLabel = periodLabel
        self.categoryLabel = categoryLabel
        self.merchantFilter = merchantFilter
        self.minAmount = minAmount
        self.maxAmount = maxAmount
        self.limit = limit
        self.truncated = truncated
    }

    public func toJSON() -> String {
        var rowsJSON = "["
        rowsJSON += rows.map { r in
            let cat = r.categoryName.map { "\"\($0)\"" } ?? "null"
            return "{\"date\":\"\(r.date)\",\"merchant\":\"\(r.merchant)\",\"amount\":\"\(r.amount.currencyFormatted)\",\"category\":\(cat)}"
        }.joined(separator: ",")
        rowsJSON += "]"
        let cat = categoryLabel.map { "\"\($0)\"" } ?? "null"
        let merchant = merchantFilter.map { "\"\($0)\"" } ?? "null"
        let minStr = minAmount.map { "\"\($0.currencyFormatted)\"" } ?? "null"
        let maxStr = maxAmount.map { "\"\($0.currencyFormatted)\"" } ?? "null"
        return "{\"rows\":\(rowsJSON),\"total\":\"\(total.currencyFormatted)\",\"count\":\(count),\"period\":\"\(periodLabel)\",\"category\":\(cat),\"merchant\":\(merchant),\"min_amount\":\(minStr),\"max_amount\":\(maxStr),\"truncated\":\(truncated)}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        let filterLabel = describeFilters()
        if rows.isEmpty {
            switch tone {
            case .professional: return "No transactions found matching \(filterLabel)."
            case .friendly: return "I couldn't find any transactions matching \(filterLabel). Try widening the filters?"
            case .funny: return "Zero matches for \(filterLabel) — your money stayed on the bench!"
            case .strict: return "No transactions matched \(filterLabel). Adjust filters and retry."
            }
        }
        let txnWord = count == 1 ? "transaction" : "transactions"
        var list = ""
        for r in rows {
            let cat = r.categoryName.map { " · \($0)" } ?? ""
            list += "\n- \(r.date) — \(r.merchant): \(r.amount.currencyFormatted)\(cat)"
        }
        let truncatedSuffix = truncated ? "\n\n(showing first \(rows.count) of \(count))" : ""
        switch tone {
        case .professional:
            return "Found \(count) \(txnWord) matching \(filterLabel), totaling \(total.currencyFormatted):\(list)\(truncatedSuffix)"
        case .friendly:
            return "Here you go — \(count) \(txnWord) matching \(filterLabel) (total: \(total.currencyFormatted)):\(list)\(truncatedSuffix)"
        case .funny:
            return "Rounded up \(count) suspects matching \(filterLabel). Total damage: \(total.currencyFormatted).\(list)\(truncatedSuffix)"
        case .strict:
            return "\(count) \(txnWord) match \(filterLabel). Total: \(total.currencyFormatted).\(list)\(truncatedSuffix)"
        }
    }

    private func describeFilters() -> String {
        var parts: [String] = []
        if let c = categoryLabel { parts.append(c) }
        if let m = merchantFilter { parts.append("\"\(m)\"") }
        if let minA = minAmount, let maxA = maxAmount {
            parts.append("\(minA.currencyFormatted)–\(maxA.currencyFormatted)")
        } else if let minA = minAmount {
            parts.append("over \(minA.currencyFormatted)")
        } else if let maxA = maxAmount {
            parts.append("under \(maxA.currencyFormatted)")
        }
        parts.append(periodLabel)
        return parts.joined(separator: ", ")
    }
}

/// One row returned by `list_investment_transactions`.
public struct InvestmentTransactionRow: Sendable {
    public let date: String
    public let ticker: String?
    /// The Plaid subtype (dividend, buy, sell, …) falling back to the broader
    /// type. Lowercased for uniformity.
    public let type: String
    public let amount: Decimal
    public let quantity: Double?
    public let price: Decimal?

    public init(date: String, ticker: String?, type: String, amount: Decimal, quantity: Double?, price: Decimal?) {
        self.date = date
        self.ticker = ticker
        self.type = type
        self.amount = amount
        self.quantity = quantity
        self.price = price
    }
}

public struct InvestmentTransactionListResult: ToolResult, Sendable {
    public let rows: [InvestmentTransactionRow]
    public let count: Int
    public let periodLabel: String
    public let activityFilter: String?
    public let limit: Int
    public let truncated: Bool

    public var toolName: String { "list_investment_transactions" }

    public init(
        rows: [InvestmentTransactionRow],
        count: Int,
        periodLabel: String,
        activityFilter: String?,
        limit: Int,
        truncated: Bool
    ) {
        self.rows = rows
        self.count = count
        self.periodLabel = periodLabel
        self.activityFilter = activityFilter
        self.limit = limit
        self.truncated = truncated
    }

    public func toJSON() -> String {
        var rowsJSON = "["
        rowsJSON += rows.map { r in
            let ticker = r.ticker.map { "\"\($0)\"" } ?? "null"
            let qty = r.quantity.map { String(format: "%.4f", $0) } ?? "null"
            let price = r.price.map { "\"\($0.currencyFormatted)\"" } ?? "null"
            return "{\"date\":\"\(r.date)\",\"ticker\":\(ticker),\"type\":\"\(r.type)\",\"amount\":\"\(r.amount.currencyFormatted)\",\"quantity\":\(qty),\"price\":\(price)}"
        }.joined(separator: ",")
        rowsJSON += "]"
        let activity = activityFilter.map { "\"\($0)\"" } ?? "null"
        return "{\"rows\":\(rowsJSON),\"count\":\(count),\"period\":\"\(periodLabel)\",\"activity_filter\":\(activity),\"truncated\":\(truncated)}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        if rows.isEmpty {
            let label = activityFilter ?? "investment activity"
            switch tone {
            case .professional: return "No \(label) recorded \(periodLabel)."
            case .friendly: return "Nothing doing \(periodLabel) — no \(label) to show!"
            case .funny: return "Your portfolio took a nap \(periodLabel). Zero \(label)."
            case .strict: return "No \(label) \(periodLabel)."
            }
        }
        var list = ""
        for r in rows {
            let ticker = r.ticker ?? "—"
            let qtyStr: String = r.quantity.map { String(format: " · %.4f sh", $0) } ?? ""
            list += "\n- \(r.date) \(r.type.uppercased()) \(ticker): \(r.amount.currencyFormatted)\(qtyStr)"
        }
        let word = count == 1 ? "transaction" : "transactions"
        let truncatedSuffix = truncated ? "\n\n(showing first \(rows.count) of \(count))" : ""
        let label = activityFilter ?? "activity"
        switch tone {
        case .professional: return "\(count) investment \(word) (\(label), \(periodLabel)):\(list)\(truncatedSuffix)"
        case .friendly: return "Here's your \(label) \(periodLabel) — \(count) \(word):\(list)\(truncatedSuffix)"
        case .funny: return "Your portfolio's greatest hits \(periodLabel) — \(count) \(word):\(list)\(truncatedSuffix)"
        case .strict: return "\(count) \(word) for \(label) \(periodLabel). Review each:\(list)\(truncatedSuffix)"
        }
    }
}

// MARK: - Wealth tool results

/// Represents one holding row, pre-resolved with its security label and
/// unrealized P/L so the LLM / template can print it verbatim.
public struct HoldingLine: Sendable {
    public let label: String
    public let quantity: Double
    public let marketValue: Decimal
    public let unrealizedPL: Decimal?

    public init(label: String, quantity: Double, marketValue: Decimal, unrealizedPL: Decimal?) {
        self.label = label
        self.quantity = quantity
        self.marketValue = marketValue
        self.unrealizedPL = unrealizedPL
    }
}

public struct HoldingsResult: ToolResult, Sendable {
    public let totalValue: Decimal
    public let unrealizedPL: Decimal?
    public let positionCount: Int
    public let topPositions: [HoldingLine]
    /// When the user asked about a specific ticker/name this carries the
    /// filter label so the template can say "your AAPL holdings" etc.
    public let filterLabel: String?

    public var toolName: String { "holdings_query" }

    public init(
        totalValue: Decimal,
        unrealizedPL: Decimal?,
        positionCount: Int,
        topPositions: [HoldingLine],
        filterLabel: String? = nil
    ) {
        self.totalValue = totalValue
        self.unrealizedPL = unrealizedPL
        self.positionCount = positionCount
        self.topPositions = topPositions
        self.filterLabel = filterLabel
    }

    public func toJSON() -> String {
        var positions = "["
        positions += topPositions.prefix(5).map { p in
            let plStr = p.unrealizedPL.map { "\"\($0.currencyFormatted)\"" } ?? "null"
            let qty = String(format: "%.4f", p.quantity)
            return "{\"label\":\"\(p.label)\",\"quantity\":\(qty),\"value\":\"\(p.marketValue.currencyFormatted)\",\"unrealized_pl\":\(plStr)}"
        }.joined(separator: ",")
        positions += "]"
        let plStr = unrealizedPL.map { "\"\($0.currencyFormatted)\"" } ?? "null"
        let filter = filterLabel.map { "\"\($0)\"" } ?? "null"
        return "{\"total_value\":\"\(totalValue.currencyFormatted)\",\"unrealized_pl\":\(plStr),\"position_count\":\(positionCount),\"filter\":\(filter),\"top_positions\":\(positions)}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        if positionCount == 0 {
            if let f = filterLabel {
                switch tone {
                case .professional: return "No holdings found matching \"\(f)\"."
                case .friendly: return "I couldn't find any holdings matching \(f). Maybe check the ticker?"
                case .funny: return "Zero shares of \(f) detected. Either you sold them all or you're about to buy in!"
                case .strict: return "No holdings match \"\(f)\". Verify the ticker symbol."
                }
            }
            switch tone {
            case .professional: return "No investment holdings found. Link a brokerage account to see your positions."
            case .friendly: return "Looks like no brokerage has been linked yet — once you do, your positions will show up here!"
            case .funny: return "Holdings list: emptier than my fridge on a Sunday. Link a brokerage to fix that!"
            case .strict: return "No holdings on file. Connect a brokerage account."
            }
        }

        var breakdown = ""
        for p in topPositions.prefix(5) {
            let qty = p.quantity.formatted(.number.precision(.fractionLength(0...4)))
            let plSuffix: String = p.unrealizedPL.map {
                " (\($0 >= 0 ? "+" : "")\($0.currencyFormatted))"
            } ?? ""
            breakdown += "\n- \(p.label): \(qty) shares worth \(p.marketValue.currencyFormatted)\(plSuffix)"
        }
        let plLine: String = unrealizedPL.map {
            "\nUnrealized P/L: \($0 >= 0 ? "+" : "")\($0.currencyFormatted)"
        } ?? ""
        let posWord = positionCount == 1 ? "position" : "positions"
        let scope = filterLabel ?? "portfolio"

        switch tone {
        case .professional:
            return "Your \(scope) is valued at \(totalValue.currencyFormatted) across \(positionCount) \(posWord).\(plLine)\(breakdown)"
        case .friendly:
            return "Your \(scope) is sitting at \(totalValue.currencyFormatted) across \(positionCount) \(posWord).\(plLine)\(breakdown)"
        case .funny:
            return "Here's your \(scope): \(totalValue.currencyFormatted) spread across \(positionCount) \(posWord). Don't spend it all at once!\(plLine)\(breakdown)"
        case .strict:
            return "\(scope.capitalized) value: \(totalValue.currencyFormatted) across \(positionCount) \(posWord).\(plLine)\(breakdown)"
        }
    }
}

public struct LiabilityReportResult: ToolResult, Sendable {
    public struct Bucket: Sendable {
        public let kind: String  // "credit" | "mortgage" | "student"
        public let count: Int
        public let outstandingBalance: Decimal
        public let minimumPayment: Decimal?
        public let nextDueDate: String?

        public init(
            kind: String,
            count: Int,
            outstandingBalance: Decimal,
            minimumPayment: Decimal?,
            nextDueDate: String?
        ) {
            self.kind = kind
            self.count = count
            self.outstandingBalance = outstandingBalance
            self.minimumPayment = minimumPayment
            self.nextDueDate = nextDueDate
        }
    }

    public let totalOwed: Decimal
    public let buckets: [Bucket]
    public let filterKind: String?

    public var toolName: String { "liability_report" }

    public init(totalOwed: Decimal, buckets: [Bucket], filterKind: String?) {
        self.totalOwed = totalOwed
        self.buckets = buckets
        self.filterKind = filterKind
    }

    public func toJSON() -> String {
        var bucketJSON = "["
        bucketJSON += buckets.map { b in
            let min = b.minimumPayment.map { "\"\($0.currencyFormatted)\"" } ?? "null"
            let due = b.nextDueDate.map { "\"\($0)\"" } ?? "null"
            return "{\"kind\":\"\(b.kind)\",\"count\":\(b.count),\"balance\":\"\(b.outstandingBalance.currencyFormatted)\",\"min_payment\":\(min),\"next_due\":\(due)}"
        }.joined(separator: ",")
        bucketJSON += "]"
        let filter = filterKind.map { "\"\($0)\"" } ?? "null"
        return "{\"total_owed\":\"\(totalOwed.currencyFormatted)\",\"filter\":\(filter),\"buckets\":\(bucketJSON)}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        if buckets.isEmpty {
            if let f = filterKind {
                switch tone {
                case .professional: return "No \(f) liabilities on file."
                case .friendly: return "You don't have any \(f) accounts linked — nothing owed there!"
                case .funny: return "Zero \(f) debt. Either you're loaded or the bank lost your file!"
                case .strict: return "No \(f) liabilities recorded."
                }
            }
            switch tone {
            case .professional: return "No liabilities on file. Link a credit card, mortgage, or student loan account to track them here."
            case .friendly: return "Looks like you have no debts tracked yet. Link a credit card or loan to see them!"
            case .funny: return "Debt-free status: verified (or we just haven't linked any loans yet). Either way, congrats!"
            case .strict: return "No liabilities recorded. Connect relevant accounts to track debt."
            }
        }

        var lines = ""
        for b in buckets {
            let kindLabel = b.kind.capitalized
            let countWord = b.count == 1 ? "account" : "accounts"
            var line = "\n- \(kindLabel) (\(b.count) \(countWord)): \(b.outstandingBalance.currencyFormatted) owed"
            if let m = b.minimumPayment, m > 0 {
                line += ", min \(m.currencyFormatted)"
            }
            if let due = b.nextDueDate {
                line += " due \(due)"
            }
            lines += line
        }

        switch tone {
        case .professional:
            return "Total liabilities: \(totalOwed.currencyFormatted).\(lines)"
        case .friendly:
            return "Here's where your debts stand — total of \(totalOwed.currencyFormatted) across everything:\(lines)"
        case .funny:
            return "Your debt tour: \(totalOwed.currencyFormatted) total. Your future self says \"please\".\(lines)"
        case .strict:
            return "Outstanding debt: \(totalOwed.currencyFormatted). Review and prioritize payoff.\(lines)"
        }
    }
}

public struct NetWorthResult: ToolResult, Sendable {
    public let cashBalance: Decimal
    public let investmentBalance: Decimal
    public let liabilityBalance: Decimal
    public let netWorth: Decimal

    public var toolName: String { "net_worth" }

    public init(cashBalance: Decimal, investmentBalance: Decimal, liabilityBalance: Decimal) {
        self.cashBalance = cashBalance
        self.investmentBalance = investmentBalance
        self.liabilityBalance = liabilityBalance
        self.netWorth = cashBalance + investmentBalance - liabilityBalance
    }

    public func toJSON() -> String {
        "{\"cash\":\"\(cashBalance.currencyFormatted)\",\"investments\":\"\(investmentBalance.currencyFormatted)\",\"liabilities\":\"\(liabilityBalance.currencyFormatted)\",\"net_worth\":\"\(netWorth.currencyFormatted)\"}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        let assets = cashBalance + investmentBalance
        let breakdown =
            "\n- Cash accounts: \(cashBalance.currencyFormatted)" +
            "\n- Investments: \(investmentBalance.currencyFormatted)" +
            "\n- Liabilities: \(liabilityBalance.currencyFormatted)"

        switch tone {
        case .professional:
            return "Estimated net worth: \(netWorth.currencyFormatted) (assets \(assets.currencyFormatted) − liabilities \(liabilityBalance.currencyFormatted)).\(breakdown)"
        case .friendly:
            return "Your net worth is about \(netWorth.currencyFormatted) — \(assets.currencyFormatted) in assets minus \(liabilityBalance.currencyFormatted) in debts.\(breakdown)"
        case .funny:
            if netWorth > 0 {
                return "Drumroll... your net worth is \(netWorth.currencyFormatted)! Assets \(assets.currencyFormatted) vs. debts \(liabilityBalance.currencyFormatted). Not bad, tycoon.\(breakdown)"
            }
            return "Your net worth is \(netWorth.currencyFormatted). Hey, everyone starts somewhere — assets \(assets.currencyFormatted) vs. debts \(liabilityBalance.currencyFormatted).\(breakdown)"
        case .strict:
            return "Net worth: \(netWorth.currencyFormatted). Assets: \(assets.currencyFormatted). Liabilities: \(liabilityBalance.currencyFormatted). Evaluate monthly progress.\(breakdown)"
        }
    }
}

public struct InvestmentActivityResult: ToolResult, Sendable {
    public let periodLabel: String
    public let activityLabel: String  // "dividends", "trades", "all activity"
    public let totalBuys: Decimal
    public let totalSells: Decimal
    public let totalDividends: Decimal
    public let totalFees: Decimal
    public let count: Int

    public var toolName: String { "investment_activity" }

    public init(
        periodLabel: String,
        activityLabel: String,
        totalBuys: Decimal,
        totalSells: Decimal,
        totalDividends: Decimal,
        totalFees: Decimal,
        count: Int
    ) {
        self.periodLabel = periodLabel
        self.activityLabel = activityLabel
        self.totalBuys = totalBuys
        self.totalSells = totalSells
        self.totalDividends = totalDividends
        self.totalFees = totalFees
        self.count = count
    }

    public func toJSON() -> String {
        "{\"period\":\"\(periodLabel)\",\"activity\":\"\(activityLabel)\",\"count\":\(count),\"buys\":\"\(totalBuys.currencyFormatted)\",\"sells\":\"\(totalSells.currencyFormatted)\",\"dividends\":\"\(totalDividends.currencyFormatted)\",\"fees\":\"\(totalFees.currencyFormatted)\"}"
    }

    public func templateResponse(tone: ChatTone) -> String {
        if count == 0 {
            switch tone {
            case .professional: return "No investment activity \(periodLabel)."
            case .friendly: return "Quiet on the investment front \(periodLabel) — no trades, dividends, or fees."
            case .funny: return "Your portfolio did its best impression of a rock \(periodLabel). Zero activity!"
            case .strict: return "No investment activity recorded \(periodLabel)."
            }
        }
        let txnWord = count == 1 ? "transaction" : "transactions"
        let breakdown =
            "\n- Buys: \(totalBuys.currencyFormatted)" +
            "\n- Sells: \(totalSells.currencyFormatted)" +
            "\n- Dividends: \(totalDividends.currencyFormatted)" +
            "\n- Fees: \(totalFees.currencyFormatted)"

        switch tone {
        case .professional:
            return "Investment activity \(periodLabel): \(count) \(txnWord).\(breakdown)"
        case .friendly:
            return "Here's your \(activityLabel) \(periodLabel) — \(count) \(txnWord) total:\(breakdown)"
        case .funny:
            return "Your portfolio had \(count) \(txnWord) \(periodLabel). Wall Street would be proud!\(breakdown)"
        case .strict:
            return "Investment activity \(periodLabel): \(count) \(txnWord). Review each line below.\(breakdown)"
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
        case .holdingsQuery(let ticker):
            if let ticker { lastMerchant = ticker }  // reuse merchant slot for ticker context
            lastIntent = "holdings"
        case .liabilityReport(let kind):
            if let kind { lastCategory = kind }
            lastIntent = "liabilities"
        case .netWorth:
            lastIntent = "net_worth"
        case .investmentActivity(let type, let period):
            if let type { lastCategory = type }
            lastPeriod = period
            lastIntent = "investment_activity"
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
