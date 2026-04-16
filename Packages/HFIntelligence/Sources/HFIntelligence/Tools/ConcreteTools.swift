import Foundation
import HFDomain
import HFShared

// MARK: - Concrete Tool Implementations
//
// Each of these is a thin adapter — it reads its arguments out of the
// planner-emitted JSON, calls into the existing handler (SpendAggregator,
// BudgetComparator, etc.) or inlines a read against the repos, and returns
// a `ToolResult` that the synthesizer will turn into prose.
//
// Names and arg names here are the canonical identifiers the planner
// prompt teaches the LLM to use. Don't rename without updating the prompt
// in PromptAssembler.

// MARK: spending_summary

struct SpendingSummaryTool: Tool {
    let name = "spending_summary"
    let description = "Aggregate total spending and top merchants for a category or merchant over a period. Use for 'how much did I spend on X', 'my groceries this month', 'total shopping last 30 days'."
    let argsSignature = "(category?: string, merchant?: string, period?: string)"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let category = args.string("category")
        let merchant = args.string("merchant")
        let period = args.period("period", defaultTo: .thisMonth)
        return try await SpendAggregator().aggregate(
            category: category,
            merchant: merchant,
            period: period,
            transactionRepo: repos.transactions,
            categoryRepo: repos.categories
        )
    }
}

// MARK: budget_status

struct BudgetStatusTool: Tool {
    let name = "budget_status"
    let description = "Compare actual spending against the current month's budget, optionally filtered to one category. Use for 'am I over budget', 'budget status', 'how's my food budget'."
    let argsSignature = "(category?: string)"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let category = args.string("category")
        return try await BudgetComparator().compare(
            category: category,
            transactionRepo: repos.transactions,
            categoryRepo: repos.categories,
            budgetRepo: repos.budgets
        )
    }
}

// MARK: account_balance

struct AccountBalanceTool: Tool {
    let name = "account_balance"
    let description = "Return balances for linked cash/credit accounts. Optionally filter by account or institution name. Use for 'what's my balance', 'checking account', 'how much at Chase'. Does NOT compute net worth — use net_worth for that."
    let argsSignature = "(account_name?: string)"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let accountName = args.string("account_name")
        let accounts = try await repos.accounts.fetchAll()
        if let name = accountName {
            let lowered = name.lowercased()
            let filtered = accounts.filter {
                $0.accountName.lowercased().contains(lowered)
                    || $0.institutionName.lowercased().contains(lowered)
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
}

// MARK: transaction_search

struct TransactionSearchTool: Tool {
    let name = "transaction_search"
    let description = "Find recent transactions from a specific merchant or retrieve the latest transactions overall. Use for 'find charges from Starbucks', 'recent transactions', 'show my Amazon orders'."
    let argsSignature = "(merchant?: string)"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let merchant = args.string("merchant")
        guard let merchant else {
            return TransactionSearchResult(merchant: "", transactions: [], total: 0, count: 0)
        }
        let transactions = try await repos.transactions.searchByMerchant(merchant)
        let expenses = transactions.filter { $0.isExpense }
        let total = expenses.reduce(Decimal.zero) { $0 + $1.amount }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let recent = transactions.prefix(5).map { (formatter.string(from: $0.date), $0.amount) }
        return TransactionSearchResult(
            merchant: merchant,
            transactions: recent,
            total: total,
            count: transactions.count
        )
    }
}

// MARK: list_transactions

struct ListTransactionsTool: Tool {
    let name = "list_transactions"
    let description = "List individual transactions matching filters — category, merchant, date range, minimum/maximum amount. Returns row-level data (date, merchant, amount, category) rather than an aggregate. Use for 'show me every transaction over $500 this month', 'all Starbucks charges in March', 'my biggest expenses last month'."
    let argsSignature = "(category?: string, merchant?: string, period?: string, min_amount?: number, max_amount?: number, limit?: integer)"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let category = args.string("category")
        let merchant = args.string("merchant")
        let period = args.period("period", defaultTo: .thisMonth)
        let minAmount = args.double("min_amount").map { Decimal($0) }
        let maxAmount = args.double("max_amount").map { Decimal($0) }
        let rawLimit = args.int("limit") ?? 20
        let limit = min(max(rawLimit, 1), 50)

        let (start, end) = period.dateRange
        let categories = try await repos.categories.fetchAll()

        // Resolve category filter. Fuzzy contains-match mirrors SpendAggregator
        // so "food" → "Food & Dining".
        var categoryId: UUID? = nil
        var resolvedCategoryLabel: String? = nil
        if let needle = category {
            if let matched = categories.first(where: { $0.name.localizedCaseInsensitiveContains(needle) }) {
                categoryId = matched.id
                resolvedCategoryLabel = matched.name
            } else {
                resolvedCategoryLabel = needle
            }
        }

        // Prefer merchant-search path when a merchant is given — the repo
        // has a dedicated merchant lookup and we can apply the other filters
        // client-side afterwards. The SwiftData transaction repo filters
        // in-memory anyway, so there's no predicate-pushdown loss here.
        var txns: [Transaction]
        if let merchant {
            txns = try await repos.transactions.searchByMerchant(merchant)
            txns = txns.filter { $0.date >= start && $0.date <= end }
            if let catId = categoryId {
                txns = txns.filter { $0.categoryId == catId }
            }
        } else {
            txns = try await repos.transactions.fetch(
                accountId: nil, categoryId: categoryId, from: start, to: end, limit: nil
            )
        }

        // Restrict to expenses — "show me transactions over $500" almost
        // always means spending. If users want refunds/income specifically,
        // we can add an include_income flag later.
        txns = txns.filter { $0.isExpense }

        if let minA = minAmount { txns = txns.filter { $0.absoluteAmount >= minA } }
        if let maxA = maxAmount { txns = txns.filter { $0.absoluteAmount <= maxA } }

        txns.sort { $0.date > $1.date }
        let matchCount = txns.count
        let capped = Array(txns.prefix(limit))
        let total = capped.reduce(Decimal.zero) { $0 + $1.amount }

        let catNameById = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let rows: [TransactionListRow] = capped.map { t in
            TransactionListRow(
                date: formatter.string(from: t.date),
                merchant: t.merchantName ?? t.originalDescription,
                amount: t.amount,
                categoryName: t.categoryId.flatMap { catNameById[$0] }
            )
        }

        return TransactionListResult(
            rows: rows,
            total: total,
            count: matchCount,
            periodLabel: period.humanLabel,
            categoryLabel: resolvedCategoryLabel,
            merchantFilter: merchant,
            minAmount: minAmount,
            maxAmount: maxAmount,
            limit: limit,
            truncated: matchCount > limit
        )
    }
}

// MARK: list_investment_transactions

struct ListInvestmentTransactionsTool: Tool {
    let name = "list_investment_transactions"
    let description = "List individual brokerage transactions — buys, sells, dividends, fees — with ticker, quantity, price, and amount per row. Optionally filter by activity type or period. Use for 'list my recent trades', 'every dividend this year', 'last 10 investment transactions'. Returns row-level data, not totals."
    let argsSignature = "(period?: string, activity_type?: string, limit?: integer)  // activity_type ∈ {dividend, buy, sell, fee}"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let period = args.period("period", defaultTo: .lastNMonths(3))
        let activityType = args.string("activity_type")?.lowercased()
        let rawLimit = args.int("limit") ?? 20
        let limit = min(max(rawLimit, 1), 50)

        guard let repo = repos.investmentTransactions else {
            return InvestmentTransactionListResult(
                rows: [], count: 0, periodLabel: period.humanLabel,
                activityFilter: activityType, limit: limit, truncated: false
            )
        }

        let (start, end) = period.dateRange
        var txns = try await repo.fetch(from: start, to: end)

        if let t = activityType {
            txns = txns.filter { itx in
                let type = (itx.type ?? "").lowercased()
                let sub = (itx.subtype ?? "").lowercased()
                switch t {
                case "dividend": return sub == "dividend"
                case "fee": return type == "fee" || sub.contains("fee")
                case "buy": return type == "buy"
                case "sell": return type == "sell"
                default: return true
                }
            }
        }

        txns.sort { $0.date > $1.date }
        let matchCount = txns.count
        let capped = Array(txns.prefix(limit))

        // Enrich ticker via securities. If the security repo is wired, we
        // prefer ticker symbol; otherwise fall back to the security name or
        // a truncated ID.
        var secById: [String: Security] = [:]
        if let secRepo = repos.securities {
            let secs = try await secRepo.fetchAll()
            secById = Dictionary(uniqueKeysWithValues: secs.map { ($0.securityId, $0) })
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium

        let rows: [InvestmentTransactionRow] = capped.map { itx in
            let ticker: String? = {
                guard let sid = itx.securityId else { return nil }
                if let sec = secById[sid] {
                    return sec.tickerSymbol ?? sec.name
                }
                return nil
            }()
            return InvestmentTransactionRow(
                date: formatter.string(from: itx.date),
                ticker: ticker,
                type: (itx.subtype ?? itx.type ?? "activity").lowercased(),
                amount: Decimal(itx.amount ?? 0),
                quantity: itx.quantity,
                price: itx.price.map { Decimal($0) }
            )
        }

        return InvestmentTransactionListResult(
            rows: rows,
            count: matchCount,
            periodLabel: period.humanLabel,
            activityFilter: activityType,
            limit: limit,
            truncated: matchCount > limit
        )
    }
}

// MARK: spending_trend

struct SpendingTrendTool: Tool {
    let name = "spending_trend"
    let description = "Show month-over-month spending trend for a category over the last N months, plus a projected annual total. Use for 'spending trend for groceries', 'how has my food spending changed'."
    let argsSignature = "(category?: string, months?: integer)"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let category = args.string("category")
        let months = args.int("months") ?? 3
        return try await TrendCalculator().calculate(
            category: category,
            months: months,
            transactionRepo: repos.transactions,
            categoryRepo: repos.categories
        )
    }
}

// MARK: spending_anomaly

struct SpendingAnomalyTool: Tool {
    let name = "spending_anomaly"
    let description = "Detect whether current-period spending for a category is unusually high vs the 3-month baseline. Use for 'any spending spikes', 'is my dining unusually high'."
    let argsSignature = "(category?: string, period?: string)"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let category = args.string("category")
        let period = args.period("period", defaultTo: .thisMonth)
        return try await AnomalyDetector().detect(
            category: category,
            period: period,
            transactionRepo: repos.transactions,
            categoryRepo: repos.categories
        )
    }
}

// MARK: holdings_summary

struct HoldingsSummaryTool: Tool {
    let name = "holdings_summary"
    let description = "Report brokerage positions — total market value, unrealized P/L, top holdings. Optionally filter by ticker/security name and/or by linked account name. Use for 'what are my holdings', 'how much AAPL do I own', 'my portfolio', 'positions in my Fidelity account'."
    let argsSignature = "(ticker?: string, account_name?: string)"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let ticker = args.string("ticker")
        let accountName = args.string("account_name")

        guard let holdingRepo = repos.holdings, let securityRepo = repos.securities else {
            return HoldingsResult(
                totalValue: 0, unrealizedPL: nil, positionCount: 0,
                topPositions: [], filterLabel: ticker ?? accountName
            )
        }

        let holdings = try await holdingRepo.fetchAll()
        let securities = try await securityRepo.fetchAll()
        let secById = Dictionary(uniqueKeysWithValues: securities.map { ($0.securityId, $0) })

        // Resolve account_name → set of Plaid account IDs. Holding.accountId
        // is a Plaid string ID, not the domain Account.id UUID, so we look
        // up matching accounts and collect their plaidAccountId fields.
        var allowedPlaidIds: Set<String>? = nil
        var resolvedAccountLabel: String? = nil
        if let needle = accountName?.lowercased(), !needle.isEmpty {
            let accounts = try await repos.accounts.fetchAll()
            let matched = accounts.filter {
                $0.accountName.lowercased().contains(needle)
                    || $0.institutionName.lowercased().contains(needle)
            }
            allowedPlaidIds = Set(matched.map { $0.plaidAccountId })
            resolvedAccountLabel = matched.first?.accountName ?? accountName
        }

        let filtered: [Holding] = {
            var f = holdings
            if let ids = allowedPlaidIds {
                f = f.filter { ids.contains($0.accountId) }
            }
            if let needle = ticker?.lowercased(), !needle.isEmpty {
                f = f.filter { h in
                    guard let sec = secById[h.securityId] else { return false }
                    return (sec.tickerSymbol?.lowercased().contains(needle) ?? false)
                        || (sec.name?.lowercased().contains(needle) ?? false)
                }
            }
            return f
        }()

        let totalValue = filtered.reduce(0.0) { $0 + ($1.institutionValue ?? 0) }
        let plDecimalSummed: Decimal? = {
            let anyMissing = filtered.contains { $0.costBasis == nil || $0.institutionValue == nil }
            if anyMissing || filtered.isEmpty { return nil }
            let pl = filtered.reduce(0.0) { $0 + (($1.institutionValue ?? 0) - ($1.costBasis ?? 0)) }
            return Decimal(pl)
        }()

        let sorted = filtered.sorted { ($0.institutionValue ?? 0) > ($1.institutionValue ?? 0) }
        let lines: [HoldingLine] = sorted.prefix(5).map { h in
            let sec = secById[h.securityId]
            let label = sec?.tickerSymbol ?? sec?.name ?? String(h.securityId.prefix(8))
            let val = Decimal(h.institutionValue ?? 0)
            let pl: Decimal? = (h.institutionValue != nil && h.costBasis != nil)
                ? Decimal((h.institutionValue ?? 0) - (h.costBasis ?? 0))
                : nil
            return HoldingLine(label: label, quantity: h.quantity, marketValue: val, unrealizedPL: pl)
        }

        // Ticker filter wins when both are given — it's more specific than
        // the account scope. Otherwise surface whichever was actually used.
        let filterLabel: String? = ticker ?? resolvedAccountLabel

        return HoldingsResult(
            totalValue: Decimal(totalValue),
            unrealizedPL: plDecimalSummed,
            positionCount: filtered.count,
            topPositions: lines,
            filterLabel: filterLabel
        )
    }
}

// MARK: liability_report

struct LiabilityReportTool: Tool {
    let name = "liability_report"
    let description = "Summarize outstanding debts — credit cards, mortgages, student loans — with balances, minimum payments, and next due dates. Optionally filter by kind. Use for 'what do I owe', 'credit card balance', 'mortgage'."
    let argsSignature = "(kind?: string)  // kind ∈ {credit, mortgage, student}"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let kind = args.string("kind")
        return try await Self.run(kind: kind, repos: repos)
    }

    /// Exposed so NetWorthTool can reuse the same aggregation logic without
    /// duplicating the grouping code.
    static func run(kind: String?, repos: ToolRepos) async throws -> LiabilityReportResult {
        guard let liabilityRepo = repos.liabilities else {
            return LiabilityReportResult(totalOwed: 0, buckets: [], filterKind: kind)
        }

        let liabilities = try await liabilityRepo.fetchAll()

        var creditBucket: [CreditLiability] = []
        var mortgageBucket: [MortgageLiability] = []
        var studentBucket: [StudentLiability] = []
        for l in liabilities {
            switch l {
            case .credit(let c): creditBucket.append(c)
            case .mortgage(let m): mortgageBucket.append(m)
            case .student(let s): studentBucket.append(s)
            }
        }

        let wants: (String) -> Bool = { k in
            guard let filter = kind?.lowercased() else { return true }
            return filter == k
        }

        var buckets: [LiabilityReportResult.Bucket] = []
        var totalOwed: Decimal = 0

        if wants("credit"), !creditBucket.isEmpty {
            let total = creditBucket.reduce(0.0) { $0 + ($1.lastStatementBalance ?? 0) }
            let minPay = creditBucket.reduce(0.0) { $0 + ($1.minimumPaymentAmount ?? 0) }
            let next = creditBucket.compactMap { $0.nextPaymentDueDate }.sorted().first
            buckets.append(.init(
                kind: "credit",
                count: creditBucket.count,
                outstandingBalance: Decimal(total),
                minimumPayment: minPay > 0 ? Decimal(minPay) : nil,
                nextDueDate: next
            ))
            totalOwed += Decimal(total)
        }
        if wants("mortgage"), !mortgageBucket.isEmpty {
            // Plaid doesn't expose current mortgage principal, so we use
            // the origination amount as an upper-bound proxy. See
            // notes in the old ToolDispatcher.handleLiabilities.
            let total = mortgageBucket.reduce(0.0) { $0 + ($1.originationPrincipalAmount ?? 0) }
            let monthly = mortgageBucket.reduce(0.0) { $0 + ($1.nextMonthlyPayment ?? 0) }
            let next = mortgageBucket.compactMap { $0.nextPaymentDueDate }.sorted().first
            buckets.append(.init(
                kind: "mortgage",
                count: mortgageBucket.count,
                outstandingBalance: Decimal(total),
                minimumPayment: monthly > 0 ? Decimal(monthly) : nil,
                nextDueDate: next
            ))
            totalOwed += Decimal(total)
        }
        if wants("student"), !studentBucket.isEmpty {
            let total = studentBucket.reduce(0.0) { $0 + ($1.originationPrincipalAmount ?? 0) }
            let minPay = studentBucket.reduce(0.0) { $0 + ($1.minimumPaymentAmount ?? 0) }
            let next = studentBucket.compactMap { $0.nextPaymentDueDate }.sorted().first
            buckets.append(.init(
                kind: "student",
                count: studentBucket.count,
                outstandingBalance: Decimal(total),
                minimumPayment: minPay > 0 ? Decimal(minPay) : nil,
                nextDueDate: next
            ))
            totalOwed += Decimal(total)
        }

        return LiabilityReportResult(totalOwed: totalOwed, buckets: buckets, filterKind: kind)
    }
}

// MARK: net_worth

struct NetWorthTool: Tool {
    let name = "net_worth"
    let description = "Compute total net worth = cash + investments − liabilities. Use for 'what's my net worth', 'how much am I worth', 'what are my assets'."
    let argsSignature = "()"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        // Cash = sum of active, non-investment accounts (investment accounts
        // are covered by the holdings repo total; counting both would
        // double-count brokerage balances).
        let accounts = try await repos.accounts.fetchAll()
        let cash = accounts
            .filter { $0.isActive && $0.accountType != .investment }
            .reduce(Decimal.zero) { $0 + $1.currentBalance }

        let investments: Decimal
        if let holdingRepo = repos.holdings {
            investments = try await holdingRepo.totalValue()
        } else {
            investments = accounts
                .filter { $0.isActive && $0.accountType == .investment }
                .reduce(Decimal.zero) { $0 + $1.currentBalance }
        }

        let liabReport = try await LiabilityReportTool.run(kind: nil, repos: repos)

        return NetWorthResult(
            cashBalance: cash,
            investmentBalance: investments,
            liabilityBalance: liabReport.totalOwed
        )
    }
}

// MARK: investment_activity

struct InvestmentActivityTool: Tool {
    let name = "investment_activity"
    let description = "Summarize brokerage activity over a period — buys, sells, dividends, fees. Optionally filter to one activity type. Use for 'my dividends', 'recent trades', 'investment fees this year'."
    let argsSignature = "(activity_type?: string, period?: string)  // activity_type ∈ {dividend, buy, sell, fee}"

    func execute(args: [String: ToolArgValue], repos: ToolRepos) async throws -> any ToolResult {
        let type = args.string("activity_type")
        let period = args.period("period", defaultTo: .lastNMonths(3))

        guard let repo = repos.investmentTransactions else {
            return InvestmentActivityResult(
                periodLabel: period.humanLabel,
                activityLabel: type ?? "activity",
                totalBuys: 0, totalSells: 0, totalDividends: 0, totalFees: 0,
                count: 0
            )
        }

        let (start, end) = period.dateRange
        let all = try await repo.fetch(from: start, to: end)

        // Plaid signs buys as positive and sells as negative — normalise to
        // absolute dollar totals per bucket so the template can print them.
        var buys: Double = 0, sells: Double = 0, divs: Double = 0, fees: Double = 0
        for t in all {
            let amt = t.amount ?? 0
            let plaidType = (t.type ?? "").lowercased()
            let subtype = (t.subtype ?? "").lowercased()
            if subtype == "dividend" {
                divs += Swift.abs(amt)
            } else if plaidType == "fee" || subtype.contains("fee") {
                fees += Swift.abs(amt)
            } else if plaidType == "buy" {
                buys += Swift.abs(amt)
            } else if plaidType == "sell" {
                sells += Swift.abs(amt)
            }
        }

        let filteredCount: Int
        let label: String
        switch type?.lowercased() {
        case "dividend":
            filteredCount = all.filter { ($0.subtype ?? "").lowercased() == "dividend" }.count
            label = "dividends"
        case "fee":
            filteredCount = all.filter {
                let t = ($0.type ?? "").lowercased()
                let s = ($0.subtype ?? "").lowercased()
                return t == "fee" || s.contains("fee")
            }.count
            label = "fees"
        case "buy":
            filteredCount = all.filter { ($0.type ?? "").lowercased() == "buy" }.count
            label = "buys"
        case "sell":
            filteredCount = all.filter { ($0.type ?? "").lowercased() == "sell" }.count
            label = "sells"
        default:
            filteredCount = all.count
            label = "investment activity"
        }

        return InvestmentActivityResult(
            periodLabel: period.humanLabel,
            activityLabel: label,
            totalBuys: Decimal(buys),
            totalSells: Decimal(sells),
            totalDividends: Decimal(divs),
            totalFees: Decimal(fees),
            count: filteredCount
        )
    }
}
