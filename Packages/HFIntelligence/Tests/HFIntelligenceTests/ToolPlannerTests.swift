import XCTest
import HFDomain
@testable import HFIntelligence

// MARK: - ToolPlannerTests
//
// Unit tests for the planner's routing decisions. These tests avoid the
// actual LLM (no model loaded in test environment) — they exercise the
// heuristic path and the semantic-router integration points.

final class ToolPlannerTests: XCTestCase {

    // MARK: Helpers

    private func makeRegistry() async -> ToolRegistry {
        let registry = ToolRegistry()
        // Use a minimal empty repo set — these tests don't execute tools,
        // only check that plans are routed correctly.
        return registry
    }

    private func makeInferenceEngine() -> InferenceEngine {
        // Passing a ModelManager without a loaded model is fine — tests pass
        // `modelLoaded: false` so the engine is never invoked.
        let manager = ModelManager()
        return InferenceEngine(modelManager: manager)
    }

    // MARK: Greeting short-circuit

    func testPlan_greeting_returnsEmptySource() async throws {
        let planner = ToolPlanner()
        let registry = await makeRegistry()
        let engine = makeInferenceEngine()

        let plan = await planner.plan(
            query: "hi there",
            slots: ConversationSlot(),
            registry: registry,
            inferenceEngine: engine,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .empty)
        XCTAssertTrue(plan.calls.isEmpty)
    }

    // MARK: Keyword OOS short-circuit

    func testPlan_keywordOOS_returnsUnsupported() async throws {
        let planner = ToolPlanner()
        let registry = await makeRegistry()
        let engine = makeInferenceEngine()

        let plan = await planner.plan(
            query: "how much should I save for retirement",
            slots: ConversationSlot(),
            registry: registry,
            inferenceEngine: engine,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .unsupported)
        XCTAssertTrue(plan.calls.isEmpty)
    }

    // MARK: Semantic router integration

    func testPlan_semanticRouterMatches_producesSemanticPlan() async throws {
        // Build a mock provider where "cash balance" strongly maps to
        // the account_balance exemplar with scope=cash.
        let provider = MockEmbeddingProvider(table: [
            "what is my cash balance": [1, 0, 0, 0],
            "how much cash do i have": [1, 0, 0, 0],
        ])
        let exemplars: [ToolExemplar] = [
            .init(label: "account_balance",
                  query: "what is my cash balance",
                  argsHint: ["scope": "cash"]),
        ]
        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: exemplars)

        // Registry needs to whitelist the tool name or the planner skips it.
        let registry = ToolRegistry()
        // ToolRegistry.init preloads all tools, so account_balance is
        // already registered.

        let planner = ToolPlanner()
        let plan = await planner.plan(
            query: "how much cash do i have",
            slots: ConversationSlot(),
            registry: registry,
            inferenceEngine: makeInferenceEngine(),
            semanticRouter: router,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .semantic)
        XCTAssertEqual(plan.calls.count, 1)
        XCTAssertEqual(plan.calls.first?.name, "account_balance")
        XCTAssertEqual(plan.calls.first?.args.string("scope"), "cash")
    }

    func testPlan_semanticRouterOOS_returnsUnsupported() async throws {
        let provider = MockEmbeddingProvider(table: [
            "should i invest in tesla": [0, 0, 1, 0],
            "is aapl a buy": [0, 0, 1, 0],
        ])
        let exemplars: [ToolExemplar] = [
            .init(label: OutOfScopeLabel, query: "should i invest in tesla"),
        ]
        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: exemplars)

        let planner = ToolPlanner()
        let plan = await planner.plan(
            query: "is aapl a buy",
            slots: ConversationSlot(),
            registry: ToolRegistry(),
            inferenceEngine: makeInferenceEngine(),
            semanticRouter: router,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .unsupported)
    }

    func testPlan_semanticRouterUncertain_fallsThroughToHeuristic() async throws {
        // Router unavailable / uncertain → planner should fall through
        // to the keyword heuristic, which matches "balance".
        let provider = MockEmbeddingProvider(table: [:])  // empty — all embeddings return zero
        let router = SemanticRouter(provider: provider)
        // No prewarm — router is unavailable

        let planner = ToolPlanner()
        let plan = await planner.plan(
            query: "what is my balance",
            slots: ConversationSlot(),
            registry: ToolRegistry(),
            inferenceEngine: makeInferenceEngine(),
            semanticRouter: router,
            modelLoaded: false
        )

        XCTAssertEqual(plan.source, .heuristic,
                       "Uncertain router should fall through to keyword heuristic")
        XCTAssertEqual(plan.calls.first?.name, "account_balance")
    }

    // MARK: convertArgsHint

    func testConvertArgsHint_parsesNumericFields() {
        let hint = [
            "scope": "cash",
            "min_amount": "500",
            "max_amount": "1000.5",
            "limit": "25",
            "months": "6"
        ]
        let out = ToolPlanner.convertArgsHint(hint)

        XCTAssertEqual(out["scope"], .string("cash"))
        XCTAssertEqual(out["min_amount"], .integer(500))
        XCTAssertEqual(out["max_amount"], .number(1000.5))
        XCTAssertEqual(out["limit"], .integer(25))
        XCTAssertEqual(out["months"], .integer(6))
    }

    func testConvertArgsHint_keepsNonNumericAsStrings() {
        let hint = ["category": "Groceries", "merchant": "Amazon"]
        let out = ToolPlanner.convertArgsHint(hint)

        XCTAssertEqual(out["category"], .string("Groceries"))
        XCTAssertEqual(out["merchant"], .string("Amazon"))
    }

    // MARK: Heuristic fallback

    func testHeuristic_recognizesBTCAsHoldings() {
        let planner = ToolPlanner()
        let calls = planner.heuristicPlan(for: "how much BTC do I have")

        XCTAssertEqual(calls.first?.name, "holdings_summary")
        XCTAssertEqual(calls.first?.args.string("ticker"), "BTC")
    }

    func testHeuristic_recognizesCryptoAsHoldings() {
        let planner = ToolPlanner()
        let calls = planner.heuristicPlan(for: "how much crypto do I have")

        XCTAssertEqual(calls.first?.name, "holdings_summary")
    }

    func testHeuristic_spendingKeywords() {
        let planner = ToolPlanner()
        let calls = planner.heuristicPlan(for: "how much did I spend")

        XCTAssertEqual(calls.first?.name, "spending_summary")
    }
}
