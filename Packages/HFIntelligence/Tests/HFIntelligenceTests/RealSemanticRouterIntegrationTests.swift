import XCTest
import HFDomain
@testable import HFIntelligence

// MARK: - RealSemanticRouterIntegrationTests
//
// Integration tests that exercise the REAL NLEmbeddingProvider + REAL
// ToolExemplars.all seed data against real user-style queries. These
// validate that the cold-start router actually works in production.
//
// Unlike the unit tests with MockEmbeddingProvider, these can be flaky
// if Apple ships a new NLEmbedding build or retrains it — that's fine,
// the unit tests cover router logic; these cover END-TO-END cold-start
// QUALITY (how well the seed data discriminates real phrasings).
//
// If you're adding a new tool, add an integration test here that
// verifies queries for that tool reach it via the router.

final class RealSemanticRouterIntegrationTests: XCTestCase {

    private var router: SemanticRouter!

    override func setUp() async throws {
        try await super.setUp()
        let provider = NLEmbeddingProvider()
        // If NLEmbedding isn't available on the test platform, skip.
        let dims = await provider.dimensions
        try XCTSkipIf(dims == 0, "NLEmbedding unavailable — skipping integration tests")

        router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: ToolExemplars.all)
        let available = await router.isAvailable
        try XCTSkipUnless(available, "Router prewarm failed")
    }

    // MARK: Helpers

    private func assertRoutesTo(
        _ query: String,
        expected: String,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        let decision = await router.route(query: query)
        switch decision {
        case .tool(let name, _, let confidence):
            XCTAssertEqual(name, expected,
                           "Expected '\(query)' → \(expected), got \(name) (conf=\(confidence))",
                           file: file, line: line)
        case .outOfScope(let confidence):
            if expected == OutOfScopeLabel {
                return  // correct
            }
            XCTFail("Expected '\(query)' → \(expected), got OOS (conf=\(confidence))",
                    file: file, line: line)
        case .uncertain(let topLabel, let topScore):
            XCTFail("Expected '\(query)' → \(expected), got uncertain (top=\(topLabel ?? "nil"), score=\(topScore ?? 0))",
                    file: file, line: line)
        }
    }

    private func assertOOS(_ query: String, file: StaticString = #file, line: UInt = #line) async {
        let decision = await router.route(query: query)
        if case .outOfScope = decision { return }
        XCTFail("Expected '\(query)' → OOS, got \(decision)", file: file, line: line)
    }

    private func assertHasScope(
        _ query: String,
        scope: String,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        let decision = await router.route(query: query)
        if case .tool(_, let hint, _) = decision {
            XCTAssertEqual(hint["scope"], scope,
                           "Expected '\(query)' to produce scope=\(scope), got \(hint["scope"] ?? "nil")",
                           file: file, line: line)
        } else {
            XCTFail("Expected '\(query)' → tool with scope=\(scope), got \(decision)",
                    file: file, line: line)
        }
    }

    // MARK: Account balance variations

    func test_realRouter_cashBalanceVariations_allRouteToAccountBalance() async throws {
        // Every one of these should map to account_balance. Confidence may
        // vary but the label should be stable.
        let phrasings = [
            "what is my cash balance",
            "how much cash do I have",
            "my checking account balance",
            "balance in my savings",
        ]
        for q in phrasings {
            await assertRoutesTo(q, expected: "account_balance")
        }
    }

    func test_realRouter_cashQueries_includeScopeHint() async throws {
        // Queries that mention "cash" specifically should carry scope=cash.
        // (Generic "balance" queries may not — that's fine, the tool
        //  defaults to "all" when scope is absent.)
        await assertHasScope("what is my cash balance", scope: "cash")
        await assertHasScope("how much cash do I have", scope: "cash")
    }

    // MARK: Spending queries

    func test_realRouter_spendingQueries() async throws {
        await assertRoutesTo("how much did I spend on groceries this month",
                             expected: "spending_summary")
        await assertRoutesTo("total expenses last month",
                             expected: "spending_summary")
    }

    // MARK: Holdings queries

    func test_realRouter_holdingsQueries() async throws {
        await assertRoutesTo("what are my holdings", expected: "holdings_summary")
        await assertRoutesTo("my portfolio", expected: "holdings_summary")
        await assertRoutesTo("show me my investments", expected: "holdings_summary")
    }

    // MARK: Net worth

    func test_realRouter_netWorthQueries() async throws {
        await assertRoutesTo("what is my net worth", expected: "net_worth")
        await assertRoutesTo("how much am I worth", expected: "net_worth")
    }

    // MARK: Liabilities

    func test_realRouter_debtQueries() async throws {
        await assertRoutesTo("what do I owe", expected: "liability_report")
        await assertRoutesTo("my credit card debt", expected: "liability_report")
    }

    // MARK: Out of scope

    func test_realRouter_stockPickingIsOOS() async throws {
        await assertOOS("should I buy tesla stock")
        await assertOOS("is AAPL a good buy")
    }

    func test_realRouter_marketForecastsAreOOS() async throws {
        await assertOOS("will stocks go up next year")
        await assertOOS("what will the market do")
    }

    func test_realRouter_retirementAdviceIsOOS() async throws {
        await assertOOS("how much should I save for retirement")
        await assertOOS("am I on track for retirement")
    }
}
