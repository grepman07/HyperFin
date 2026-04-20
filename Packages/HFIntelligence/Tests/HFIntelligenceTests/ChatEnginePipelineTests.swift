import XCTest
import HFDomain
@testable import HFIntelligence

// MARK: - ChatEnginePipelineTests
//
// End-to-end tests for the Plan → Execute → Synthesize pipeline. These
// exercise the actual ChatEngine with:
//   - Real AccountBalanceTool / HoldingsSummaryTool / NetWorthTool
//   - Mock SwiftData repos holding test fixtures
//   - The semantic router wired up with a deterministic mock provider
//   - No LLM (modelLoaded=false) — routing goes through the semantic +
//     heuristic paths, which is exactly what we care about for UAT.
//
// We verify both the PLAN (which tools were chosen, with which args) and
// the EXECUTE result shape (correct numbers, correct scope label). Since
// there's no LLM, synthesis falls back to templateResponse — that's fine,
// we assert on the tool-result structure rather than the prose.
//
// These tests are the foundation of UAT. Every scenario here corresponds
// to a row in docs/CHAT_UAT.md.

@MainActor
final class ChatEnginePipelineTests: XCTestCase {

    // MARK: - Fixtures

    private func makeAccounts() -> [Account] {
        [
            Account(plaidAccountId: "chk_1", institutionName: "Chase",
                    accountName: "Primary Checking", accountType: .checking,
                    currentBalance: Decimal(1000)),
            Account(plaidAccountId: "sav_1", institutionName: "Chase",
                    accountName: "Savings", accountType: .savings,
                    currentBalance: Decimal(5000)),
            Account(plaidAccountId: "cc_1", institutionName: "Amex",
                    accountName: "Amex Gold", accountType: .credit,
                    currentBalance: Decimal(-450)),
            Account(plaidAccountId: "inv_1", institutionName: "Vanguard",
                    accountName: "IRA", accountType: .investment,
                    currentBalance: Decimal(158000)),
        ]
    }

    private func makeRegistry(with accounts: [Account]) async -> ToolRegistry {
        let registry = ToolRegistry()
        let accountRepo = MockAccountRepo()
        accountRepo.accounts = accounts

        let repos = ToolRepos(
            transactions: StubTransactionRepo(),
            categories: StubCategoryRepo(),
            accounts: accountRepo,
            budgets: StubBudgetRepo()
        )
        await registry.setRepos(repos)
        return registry
    }

    /// Build a semantic router with the real seed exemplars. Uses a
    /// deterministic hash-based mock provider so tests don't depend on
    /// NLEmbedding (which would require loading Apple's embedding model).
    private func makeSemanticRouter(seedEmbeddings: [String: [Float]]) async -> SemanticRouter {
        let provider = MockEmbeddingProvider(table: seedEmbeddings)
        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: Array(seedEmbeddings.keys).map { key in
            ToolExemplar(label: labelForSeed(key), query: key,
                         argsHint: argsForSeed(key))
        })
        return router
    }

    // Test helper: crude label/args mapping for the seed queries we embed.
    private func labelForSeed(_ query: String) -> String {
        let q = query.lowercased()
        if q.contains("market") || q.contains("buy") { return OutOfScopeLabel }
        if q.contains("cash") || q.contains("checking") { return "account_balance" }
        if q.contains("balance") { return "account_balance" }
        if q.contains("spending") || q.contains("spend") { return "spending_summary" }
        if q.contains("portfolio") || q.contains("holdings") { return "holdings_summary" }
        if q.contains("net worth") { return "net_worth" }
        return "account_balance"
    }

    private func argsForSeed(_ query: String) -> [String: String] {
        let q = query.lowercased()
        if q.contains("cash") { return ["scope": "cash"] }
        return [:]
    }

    // MARK: - Scenario 1: "What is my cash balance?"

    func test_e2e_cashBalance_routesViaSemantic_filtersToCashOnly() async throws {
        // Arrange
        let accounts = makeAccounts()
        let registry = await makeRegistry(with: accounts)
        let router = await makeSemanticRouter(seedEmbeddings: [
            "what is my cash balance": [1, 0, 0, 0],
            "how much cash do I have": [1, 0, 0, 0],
            "what is my balance": [0, 1, 0, 0],
            "should I buy apple": [0, 0, 1, 0],
        ])

        let planner = ToolPlanner()

        // Act
        let plan = await planner.plan(
            query: "how much cash do I have",
            slots: ConversationSlot(),
            registry: registry,
            inferenceEngine: InferenceEngine(modelManager: ModelManager()),
            semanticRouter: router,
            modelLoaded: false
        )

        // Assert: plan
        XCTAssertEqual(plan.source, .semantic)
        XCTAssertEqual(plan.calls.count, 1)
        XCTAssertEqual(plan.calls.first?.name, "account_balance")
        XCTAssertEqual(plan.calls.first?.args.string("scope"), "cash")

        // Execute and verify result
        guard let call = plan.calls.first else {
            XCTFail("No call in plan")
            return
        }
        let result = try await registry.execute(call) as! AccountBalanceResult

        XCTAssertEqual(result.scopeLabel, "cash", "Result must be labeled as cash")
        XCTAssertEqual(result.totalBalance, Decimal(6000), "Should be checking + savings only")
        XCTAssertEqual(result.accounts.count, 2)

        // Critical: NO investment account in output
        XCTAssertFalse(result.accounts.contains { $0.type == "investment" },
                       "Investment account must not appear in cash-scoped result")
    }

    // MARK: - Scenario 2: "What is my total balance?" (no scope)

    func test_e2e_totalBalance_noScope_includesAll() async throws {
        let accounts = makeAccounts()
        let registry = await makeRegistry(with: accounts)
        let router = await makeSemanticRouter(seedEmbeddings: [
            "what is my balance": [0, 1, 0, 0],
            "total balance across all accounts": [0, 1, 0, 0],
        ])

        let planner = ToolPlanner()
        let plan = await planner.plan(
            query: "total balance across all accounts",
            slots: ConversationSlot(),
            registry: registry,
            inferenceEngine: InferenceEngine(modelManager: ModelManager()),
            semanticRouter: router,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .semantic)
        let result = try await registry.execute(plan.calls.first!) as! AccountBalanceResult

        // All 4 accounts should appear; total = 1000+5000-450+158000 = 163550
        XCTAssertEqual(result.accounts.count, 4)
        XCTAssertEqual(result.totalBalance, Decimal(163550))
        XCTAssertNil(result.scopeLabel, "Default scope emits no label")
    }

    // MARK: - Scenario 3: OOS query refused

    func test_e2e_stockAdvice_routesToUnsupported() async throws {
        let registry = await makeRegistry(with: makeAccounts())
        let router = await makeSemanticRouter(seedEmbeddings: [
            "should I buy apple": [0, 0, 1, 0],
            "is tsla a good buy": [0, 0, 1, 0],
            "what is my balance": [1, 0, 0, 0],
        ])

        let planner = ToolPlanner()
        let plan = await planner.plan(
            query: "is tsla a good buy",
            slots: ConversationSlot(),
            registry: registry,
            inferenceEngine: InferenceEngine(modelManager: ModelManager()),
            semanticRouter: router,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .unsupported)
        XCTAssertTrue(plan.calls.isEmpty, "Unsupported plans execute no tools")
    }

    // MARK: - Scenario 4: Greeting

    func test_e2e_greeting_returnsEmpty_noToolsExecuted() async throws {
        let registry = await makeRegistry(with: makeAccounts())
        let router = await makeSemanticRouter(seedEmbeddings: [:])
        let planner = ToolPlanner()

        let plan = await planner.plan(
            query: "hi",
            slots: ConversationSlot(),
            registry: registry,
            inferenceEngine: InferenceEngine(modelManager: ModelManager()),
            semanticRouter: router,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .empty)
        XCTAssertTrue(plan.calls.isEmpty)
    }

    // MARK: - Scenario 5: Keyword OOS still fires first

    func test_e2e_retirementQuery_keywordOOSBypassesRouter() async throws {
        // Even with a faulty router pointing retirement to account_balance,
        // the keyword pre-filter should catch "retirement" first.
        let registry = await makeRegistry(with: makeAccounts())
        let router = await makeSemanticRouter(seedEmbeddings: [
            "how much for retirement": [1, 0, 0, 0],  // bad mapping
            "what is my balance": [1, 0, 0, 0],
        ])

        let planner = ToolPlanner()
        let plan = await planner.plan(
            query: "how much should I save for retirement",
            slots: ConversationSlot(),
            registry: registry,
            inferenceEngine: InferenceEngine(modelManager: ModelManager()),
            semanticRouter: router,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .unsupported,
                       "Keyword OOS must fire before semantic router")
    }

    // MARK: - Scenario 6: Heuristic fallback when router is unavailable

    func test_e2e_routerUnavailable_fallsThroughToHeuristic() async throws {
        let registry = await makeRegistry(with: makeAccounts())
        // Router never prewarmed → not available
        let router = SemanticRouter(provider: MockEmbeddingProvider(table: [:]))

        let planner = ToolPlanner()
        let plan = await planner.plan(
            query: "what is my balance",
            slots: ConversationSlot(),
            registry: registry,
            inferenceEngine: InferenceEngine(modelManager: ModelManager()),
            semanticRouter: router,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .heuristic)
        XCTAssertEqual(plan.calls.first?.name, "account_balance")
    }

    // MARK: - Scenario 7: ChatEngine telemetry captures planJSON + planSource

    func test_chatEngine_recordsPlanJSONForTelemetry() async throws {
        let registry = await makeRegistry(with: makeAccounts())
        let router = await makeSemanticRouter(seedEmbeddings: [
            "what is my cash balance": [1, 0, 0, 0],
        ])

        let engine = ChatEngine(
            inferenceEngine: InferenceEngine(modelManager: ModelManager()),
            modelManager: ModelManager(),
            registry: registry,
            cloudEngine: nil,
            semanticRouter: router
        )

        // Simulate one turn through the engine. We consume the stream to
        // completion so the engine finishes writing lastPlanSource/JSON.
        let stream = await engine.sendMessage(
            "what is my cash balance",
            context: ChatContext(sessionId: UUID(), recentMessages: [])
        )
        for try await _ in stream {}

        let source = await engine.lastPlanSource()
        let json = await engine.lastPlanJSON()

        XCTAssertEqual(source, "semantic")
        XCTAssertTrue(json.contains("\"name\":\"account_balance\""),
                      "planJSON must capture the executed tool: \(json)")
        XCTAssertTrue(json.contains("\"scope\":\"cash\""),
                      "planJSON must capture args: \(json)")
    }

    func test_chatEngine_encodesEmptyPlanJSONForGreetings() async throws {
        let registry = await makeRegistry(with: makeAccounts())
        let engine = ChatEngine(
            inferenceEngine: InferenceEngine(modelManager: ModelManager()),
            modelManager: ModelManager(),
            registry: registry,
            cloudEngine: nil,
            semanticRouter: nil
        )

        let stream = await engine.sendMessage(
            "hi",
            context: ChatContext(sessionId: UUID(), recentMessages: [])
        )
        for try await _ in stream {}

        let source = await engine.lastPlanSource()
        let json = await engine.lastPlanJSON()

        XCTAssertEqual(source, "empty")
        XCTAssertTrue(json.isEmpty, "Greetings produce no plan JSON")
    }
}
