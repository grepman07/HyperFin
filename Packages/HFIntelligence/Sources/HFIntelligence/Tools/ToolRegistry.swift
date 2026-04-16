import Foundation
import HFDomain
import HFShared

// MARK: - ToolRepos

/// Bundle of every repository any tool might need. Grouping them here keeps
/// `Tool.execute` signatures short and means ChatEngine only has to wire
/// the graph once at startup.
///
/// Wealth repos are optional since tests that only exercise the spending
/// pipeline don't bother wiring a brokerage. In production (AppDependencies)
/// all eight are always non-nil.
public struct ToolRepos: Sendable {
    public let transactions: TransactionRepository
    public let categories: CategoryRepository
    public let accounts: AccountRepository
    public let budgets: BudgetRepository
    public let holdings: HoldingRepository?
    public let securities: SecurityRepository?
    public let investmentTransactions: InvestmentTransactionRepository?
    public let liabilities: LiabilityRepository?

    public init(
        transactions: TransactionRepository,
        categories: CategoryRepository,
        accounts: AccountRepository,
        budgets: BudgetRepository,
        holdings: HoldingRepository? = nil,
        securities: SecurityRepository? = nil,
        investmentTransactions: InvestmentTransactionRepository? = nil,
        liabilities: LiabilityRepository? = nil
    ) {
        self.transactions = transactions
        self.categories = categories
        self.accounts = accounts
        self.budgets = budgets
        self.holdings = holdings
        self.securities = securities
        self.investmentTransactions = investmentTransactions
        self.liabilities = liabilities
    }
}

// MARK: - ToolRegistry

/// Central registry that owns the tool catalog and the live repo graph.
/// The planner reads `catalogText()` to render tool options into its prompt;
/// the executor calls `execute(_:)` to dispatch one tool invocation.
///
/// It's an actor because the repo graph is updated via `setRepos` after
/// SwiftData is ready (same pattern as the old ChatEngine.setRepositories).
/// Concurrent tool execution goes through `execute(_:)` which reads (not
/// mutates) the repo snapshot, so parallel calls are safe.
public actor ToolRegistry {
    private var tools: [String: any Tool] = [:]
    private var _repos: ToolRepos?

    public init() {
        // Pre-register every default tool. We populate the dictionary
        // directly here (not through a helper) because Swift 6 treats
        // calls to actor-isolated methods inside init as a cross-actor
        // hop that the sync init can't make.
        let all: [any Tool] = [
            SpendingSummaryTool(),
            BudgetStatusTool(),
            AccountBalanceTool(),
            TransactionSearchTool(),
            ListTransactionsTool(),
            SpendingTrendTool(),
            SpendingAnomalyTool(),
            HoldingsSummaryTool(),
            LiabilityReportTool(),
            NetWorthTool(),
            InvestmentActivityTool(),
            ListInvestmentTransactionsTool(),
        ]
        var initial: [String: any Tool] = [:]
        for t in all { initial[t.name] = t }
        self.tools = initial
    }

    // MARK: Registration

    public func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    public func setRepos(_ repos: ToolRepos) {
        self._repos = repos
    }

    // MARK: Planner support

    /// Render a newline-separated catalog suitable for inclusion in the
    /// planner's system prompt. Listed in a deterministic order so the
    /// planner sees the same menu every call — stable prompts improve
    /// classification reliability on small models.
    public func catalogText() -> String {
        tools.values
            .sorted { $0.name < $1.name }
            .map { $0.catalogLine }
            .joined(separator: "\n")
    }

    /// List of tool names, alphabetised. Used to build the "valid tool
    /// names" whitelist in the planner prompt.
    public func toolNames() -> [String] {
        tools.keys.sorted()
    }

    public func hasTool(_ name: String) -> Bool {
        tools[name] != nil
    }

    // MARK: Execution

    public enum RegistryError: Error, LocalizedError {
        case reposNotConfigured
        case unknownTool(String)

        public var errorDescription: String? {
            switch self {
            case .reposNotConfigured: return "Tool repositories have not been configured yet."
            case .unknownTool(let n): return "Unknown tool: \(n)"
            }
        }
    }

    /// Execute one tool call. Throws if the registry hasn't been wired with
    /// repos yet (startup race), or if the planner emitted a tool name that
    /// doesn't exist. Individual tool failures bubble up as-is.
    public func execute(_ call: ToolCall) async throws -> any ToolResult {
        guard let repos = _repos else { throw RegistryError.reposNotConfigured }
        guard let tool = tools[call.name] else { throw RegistryError.unknownTool(call.name) }
        return try await tool.execute(args: call.args, repos: repos)
    }
}
