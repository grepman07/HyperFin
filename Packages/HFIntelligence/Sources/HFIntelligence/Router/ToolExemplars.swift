import Foundation

// MARK: - ToolExemplars
//
// Seed data for the semantic router. Each entry is a natural-language
// query paired with the tool that should handle it. At startup these are
// embedded once and cached in memory; at query time we embed the user
// input and find the top-k closest exemplars by cosine similarity.
//
// The label `_OOS_` (out-of-scope) is special — it marks queries that
// should be declined rather than routed. The router treats `_OOS_` as
// just another label, so its decision boundary is learned from data,
// not from a hand-written keyword list.
//
// For each tool we aim for 10-15 varied surface forms covering the
// phrasings users actually use. This is *cold-start* data — the
// telemetry flywheel will eventually expand it with real user queries,
// and a contrastive fine-tune will tighten the decision boundaries.

public struct ToolExemplar: Sendable, Equatable {
    public let label: String      // tool name or "_OOS_"
    public let query: String      // natural-language example

    /// Optional hint args to inject when this exemplar wins. Keeps the
    /// router capable of producing useful ToolCalls for patterns that
    /// would otherwise be lost (e.g. "my groceries" → category=Groceries).
    public let argsHint: [String: String]

    public init(label: String, query: String, argsHint: [String: String] = [:]) {
        self.label = label
        self.query = query
        self.argsHint = argsHint
    }
}

/// Sentinel label used for out-of-scope queries. The router maps a top
/// match against an `_OOS_` exemplar to `Plan.Source.unsupported`.
public let OutOfScopeLabel = "_OOS_"

public enum ToolExemplars {
    /// The full seed set. Order is not significant — router sorts by
    /// similarity at query time.
    public static let all: [ToolExemplar] = [
        // ─────────── account_balance ───────────
        // Default balance queries (no scope — all accounts)
        .init(label: "account_balance", query: "what is my balance"),
        .init(label: "account_balance", query: "show me my account balances"),
        .init(label: "account_balance", query: "what are my account balances"),
        .init(label: "account_balance", query: "how much money do I have in my accounts"),
        .init(label: "account_balance", query: "balance at chase",
              argsHint: ["account_name": "chase"]),
        .init(label: "account_balance", query: "balance in my wells fargo account",
              argsHint: ["account_name": "wells fargo"]),

        // Cash-scoped queries
        .init(label: "account_balance", query: "what is my cash balance",
              argsHint: ["scope": "cash"]),
        .init(label: "account_balance", query: "how much cash do I have",
              argsHint: ["scope": "cash"]),
        .init(label: "account_balance", query: "how much liquid cash",
              argsHint: ["scope": "cash"]),
        .init(label: "account_balance", query: "total in checking and savings",
              argsHint: ["scope": "cash"]),
        .init(label: "account_balance", query: "did my paycheck hit",
              argsHint: ["scope": "cash"]),
        .init(label: "account_balance", query: "money in my checking account",
              argsHint: ["scope": "cash"]),
        .init(label: "account_balance", query: "how much in my savings",
              argsHint: ["scope": "cash"]),

        // Credit-scoped
        .init(label: "account_balance", query: "credit card balance",
              argsHint: ["scope": "credit"]),
        .init(label: "account_balance", query: "how much do I owe on my cards",
              argsHint: ["scope": "credit"]),

        // ─────────── spending_summary ───────────
        .init(label: "spending_summary", query: "how much did I spend this month"),
        .init(label: "spending_summary", query: "how much did I spend on groceries",
              argsHint: ["category": "Groceries"]),
        .init(label: "spending_summary", query: "my food spending this month",
              argsHint: ["category": "Food & Dining", "period": "this_month"]),
        .init(label: "spending_summary", query: "total spent on dining out",
              argsHint: ["category": "Food & Dining"]),
        .init(label: "spending_summary", query: "how much did I blow on uber",
              argsHint: ["merchant": "uber"]),
        .init(label: "spending_summary", query: "my amazon spending",
              argsHint: ["merchant": "amazon"]),
        .init(label: "spending_summary", query: "where is my money going"),
        .init(label: "spending_summary", query: "total expenses last month",
              argsHint: ["period": "last_month"]),
        .init(label: "spending_summary", query: "spending on shopping",
              argsHint: ["category": "Shopping"]),
        .init(label: "spending_summary", query: "entertainment expenses",
              argsHint: ["category": "Entertainment"]),
        .init(label: "spending_summary", query: "what did I spend on transportation",
              argsHint: ["category": "Transportation"]),

        // ─────────── budget_status ───────────
        .init(label: "budget_status", query: "am I over budget"),
        .init(label: "budget_status", query: "how is my budget"),
        .init(label: "budget_status", query: "budget status"),
        .init(label: "budget_status", query: "am I on track with spending"),
        .init(label: "budget_status", query: "how am I doing against my budget"),
        .init(label: "budget_status", query: "am I under budget this month"),
        .init(label: "budget_status", query: "food budget status",
              argsHint: ["category": "Food & Dining"]),
        .init(label: "budget_status", query: "did I exceed my budget"),
        .init(label: "budget_status", query: "budget for groceries",
              argsHint: ["category": "Groceries"]),
        .init(label: "budget_status", query: "how close am I to my budget limit"),

        // ─────────── transaction_search ───────────
        .init(label: "transaction_search", query: "find my starbucks charges",
              argsHint: ["merchant": "starbucks"]),
        .init(label: "transaction_search", query: "show my recent transactions"),
        .init(label: "transaction_search", query: "recent charges"),
        .init(label: "transaction_search", query: "my last few transactions"),
        .init(label: "transaction_search", query: "transactions from amazon",
              argsHint: ["merchant": "amazon"]),
        .init(label: "transaction_search", query: "charges from uber",
              argsHint: ["merchant": "uber"]),
        .init(label: "transaction_search", query: "show netflix purchases",
              argsHint: ["merchant": "netflix"]),

        // ─────────── list_transactions ───────────
        .init(label: "list_transactions", query: "show me every transaction over $500",
              argsHint: ["min_amount": "500"]),
        .init(label: "list_transactions", query: "list all my transactions this month",
              argsHint: ["period": "this_month"]),
        .init(label: "list_transactions", query: "my biggest expenses last month",
              argsHint: ["period": "last_month"]),
        .init(label: "list_transactions", query: "every grocery transaction",
              argsHint: ["category": "Groceries"]),
        .init(label: "list_transactions", query: "list transactions above 100 dollars",
              argsHint: ["min_amount": "100"]),
        .init(label: "list_transactions", query: "show me all my food purchases",
              argsHint: ["category": "Food & Dining"]),
        .init(label: "list_transactions", query: "give me a list of my transactions"),
        .init(label: "list_transactions", query: "all starbucks charges in march",
              argsHint: ["merchant": "starbucks"]),

        // ─────────── spending_trend ───────────
        .init(label: "spending_trend", query: "spending trend"),
        .init(label: "spending_trend", query: "how has my spending changed"),
        .init(label: "spending_trend", query: "grocery trend over the last few months",
              argsHint: ["category": "Groceries"]),
        .init(label: "spending_trend", query: "is my food spending increasing",
              argsHint: ["category": "Food & Dining"]),
        .init(label: "spending_trend", query: "spending over time"),
        .init(label: "spending_trend", query: "month over month spending"),
        .init(label: "spending_trend", query: "show me my spending trajectory"),

        // ─────────── spending_anomaly ───────────
        .init(label: "spending_anomaly", query: "any spending spikes"),
        .init(label: "spending_anomaly", query: "unusual spending this month"),
        .init(label: "spending_anomaly", query: "is my dining unusually high",
              argsHint: ["category": "Food & Dining"]),
        .init(label: "spending_anomaly", query: "anything out of the ordinary"),
        .init(label: "spending_anomaly", query: "did I spend more than usual"),
        .init(label: "spending_anomaly", query: "spending outliers"),

        // ─────────── holdings_summary ───────────
        .init(label: "holdings_summary", query: "what are my holdings"),
        .init(label: "holdings_summary", query: "my portfolio"),
        .init(label: "holdings_summary", query: "show me my positions"),
        .init(label: "holdings_summary", query: "my brokerage holdings"),
        .init(label: "holdings_summary", query: "my stocks"),
        .init(label: "holdings_summary", query: "my investments"),
        .init(label: "holdings_summary", query: "how much AAPL do I own",
              argsHint: ["ticker": "AAPL"]),
        .init(label: "holdings_summary", query: "how much bitcoin do I have",
              argsHint: ["ticker": "BTC"]),
        .init(label: "holdings_summary", query: "how much crypto do I have"),
        .init(label: "holdings_summary", query: "positions in my fidelity account",
              argsHint: ["account_name": "fidelity"]),
        .init(label: "holdings_summary", query: "my top holdings"),
        .init(label: "holdings_summary", query: "what stocks do I own"),
        // Retirement BALANCE (existing data) — deliberately paired with
        // the OOS retirement ADVICE exemplars below so the router learns
        // the distinction. A retirement account is just an investment
        // account; asking "how much is in it" is a holdings query.
        .init(label: "holdings_summary", query: "how much do I have in my 401k"),
        .init(label: "holdings_summary", query: "my 401k balance"),
        .init(label: "holdings_summary", query: "how much is in my IRA"),
        .init(label: "holdings_summary", query: "my retirement savings balance"),
        .init(label: "holdings_summary", query: "how much retirement savings do I have"),
        .init(label: "holdings_summary", query: "my retirement account balance"),
        .init(label: "holdings_summary", query: "how much crypto and retirement savings do I have"),

        // ─────────── liability_report ───────────
        .init(label: "liability_report", query: "what do I owe"),
        .init(label: "liability_report", query: "my debts"),
        .init(label: "liability_report", query: "total liabilities"),
        .init(label: "liability_report", query: "credit card debt",
              argsHint: ["kind": "credit"]),
        .init(label: "liability_report", query: "mortgage balance",
              argsHint: ["kind": "mortgage"]),
        .init(label: "liability_report", query: "student loan balance",
              argsHint: ["kind": "student"]),
        .init(label: "liability_report", query: "how much debt do I have"),
        .init(label: "liability_report", query: "when is my mortgage payment due",
              argsHint: ["kind": "mortgage"]),
        .init(label: "liability_report", query: "my outstanding balances"),

        // ─────────── net_worth ───────────
        .init(label: "net_worth", query: "what is my net worth"),
        .init(label: "net_worth", query: "how much am I worth"),
        .init(label: "net_worth", query: "am I rich"),
        .init(label: "net_worth", query: "am I a millionaire"),
        .init(label: "net_worth", query: "what are my total assets"),
        .init(label: "net_worth", query: "how rich am I"),
        .init(label: "net_worth", query: "my wealth"),
        .init(label: "net_worth", query: "overall financial picture"),

        // ─────────── investment_activity ───────────
        .init(label: "investment_activity", query: "my dividends",
              argsHint: ["activity_type": "dividend"]),
        .init(label: "investment_activity", query: "dividend income this year",
              argsHint: ["activity_type": "dividend", "period": "year_to_date"]),
        .init(label: "investment_activity", query: "recent trades"),
        .init(label: "investment_activity", query: "investment fees",
              argsHint: ["activity_type": "fee"]),
        .init(label: "investment_activity", query: "stocks I bought",
              argsHint: ["activity_type": "buy"]),
        .init(label: "investment_activity", query: "stocks I sold",
              argsHint: ["activity_type": "sell"]),
        .init(label: "investment_activity", query: "investment activity summary"),

        // ─────────── list_investment_transactions ───────────
        .init(label: "list_investment_transactions", query: "list my recent trades",
              argsHint: ["activity_type": "buy", "period": "last_90_days"]),
        .init(label: "list_investment_transactions", query: "every dividend this year",
              argsHint: ["activity_type": "dividend", "period": "year_to_date"]),
        .init(label: "list_investment_transactions", query: "my last 10 investment transactions"),
        .init(label: "list_investment_transactions", query: "show each buy and sell"),
        .init(label: "list_investment_transactions", query: "row by row trades"),
        .init(label: "list_investment_transactions", query: "list all my dividend payments",
              argsHint: ["activity_type": "dividend"]),

        // ─────────── OUT OF SCOPE ───────────
        // Market forecasts
        .init(label: OutOfScopeLabel, query: "what will the market do"),
        .init(label: OutOfScopeLabel, query: "market forecast"),
        .init(label: OutOfScopeLabel, query: "stock market predictions"),
        .init(label: OutOfScopeLabel, query: "where is the economy going"),
        .init(label: OutOfScopeLabel, query: "s&p outlook"),
        .init(label: OutOfScopeLabel, query: "will stocks go up next year"),

        // Stock picking / advice
        .init(label: OutOfScopeLabel, query: "should I buy tesla stock"),
        .init(label: OutOfScopeLabel, query: "is AAPL a good buy"),
        .init(label: OutOfScopeLabel, query: "is NVDA going to keep rising"),
        .init(label: OutOfScopeLabel, query: "what stocks should I invest in"),
        .init(label: OutOfScopeLabel, query: "is now a good time to buy crypto"),
        .init(label: OutOfScopeLabel, query: "recommend me a good stock"),
        .init(label: OutOfScopeLabel, query: "give me stock advice"),
        .init(label: OutOfScopeLabel, query: "should I sell my apple shares"),

        // Retirement / financial planning projections
        .init(label: OutOfScopeLabel, query: "how much should I save for retirement"),
        .init(label: OutOfScopeLabel, query: "am I on track for retirement"),
        .init(label: OutOfScopeLabel, query: "retirement planning advice"),
        .init(label: OutOfScopeLabel, query: "should I contribute to my 401k"),
        .init(label: OutOfScopeLabel, query: "roth ira vs traditional"),
        .init(label: OutOfScopeLabel, query: "what will my 401k be worth in 30 years"),
        .init(label: OutOfScopeLabel, query: "how much do I need to retire"),

        // Generic advice
        .init(label: OutOfScopeLabel, query: "how do I get out of debt"),
        .init(label: OutOfScopeLabel, query: "should I refinance my mortgage"),
        .init(label: OutOfScopeLabel, query: "best way to build wealth"),
    ]
}
