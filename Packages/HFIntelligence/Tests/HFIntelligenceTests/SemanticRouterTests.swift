import XCTest
@testable import HFIntelligence

// MARK: - MockEmbeddingProvider
//
// A deterministic embedding provider for tests. Queries map to hardcoded
// vectors via an explicit table, making assertions precise. Unknown queries
// produce a zero vector so we can test the "no similarity" case as well.

actor MockEmbeddingProvider: EmbeddingProvider {
    let providerId: String = "mock-v1"
    let dimensions: Int = 4

    /// Table is normalized to lowercased keys at construction time so
    /// tests can author in natural case without worrying about lookup
    /// collisions with the provider's case-insensitive embed().
    private var table: [String: [Float]]
    private var failOn: Set<String> = []

    init(table: [String: [Float]]) {
        var normalized: [String: [Float]] = [:]
        for (k, v) in table { normalized[k.lowercased()] = v }
        self.table = normalized
    }

    func setFailOn(_ queries: [String]) {
        self.failOn = Set(queries.map { $0.lowercased() })
    }

    func embed(_ text: String) async throws -> [Float] {
        let key = text.lowercased()
        if failOn.contains(key) {
            throw EmbeddingError.embeddingFailed("mock failure for: \(text)")
        }
        return table[key] ?? [Float](repeating: 0, count: dimensions)
    }
}

// MARK: - SemanticRouterTests

final class SemanticRouterTests: XCTestCase {

    /// Build a 4-dim vector pointing in a canonical direction.
    private func axis(_ i: Int, scale: Float = 1.0) -> [Float] {
        var v = [Float](repeating: 0, count: 4)
        v[i] = scale
        return v
    }

    // MARK: High-confidence tool routing

    func testRoute_highConfidenceTool_returnsToolDecision() async throws {
        // "balance" query and "balance" exemplar both point along axis 0 —
        // cosine similarity = 1.0, clearly above toolAccept threshold.
        let provider = MockEmbeddingProvider(table: [
            "what is my balance": axis(0),
            "how much is in my account": axis(0),  // close to balance exemplar
            "my spending this month": axis(1),
            "what will the market do": axis(2),
        ])

        let exemplars: [ToolExemplar] = [
            .init(label: "account_balance", query: "what is my balance"),
            .init(label: "spending_summary", query: "my spending this month"),
            .init(label: OutOfScopeLabel, query: "what will the market do"),
        ]

        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: exemplars)

        let decision = await router.route(query: "how much is in my account")
        if case .tool(let name, _, let confidence) = decision {
            XCTAssertEqual(name, "account_balance")
            XCTAssertGreaterThan(confidence, 0.9)
        } else {
            XCTFail("Expected .tool decision, got \(decision)")
        }
    }

    // MARK: Out-of-scope routing

    func testRoute_highConfidenceOOS_returnsOOSDecision() async throws {
        let provider = MockEmbeddingProvider(table: [
            "stock picks": axis(2),  // matches OOS exemplar direction
            "will the market crash": axis(2),
            "what is my balance": axis(0),
        ])

        let exemplars: [ToolExemplar] = [
            .init(label: OutOfScopeLabel, query: "stock picks"),
            .init(label: "account_balance", query: "what is my balance"),
        ]

        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: exemplars)

        let decision = await router.route(query: "will the market crash")
        if case .outOfScope(let confidence) = decision {
            XCTAssertGreaterThan(confidence, 0.9)
        } else {
            XCTFail("Expected .outOfScope, got \(decision)")
        }
    }

    // MARK: Uncertainty / low confidence

    func testRoute_lowConfidence_returnsUncertain() async throws {
        // Query vector points away from all exemplars — all similarities
        // will be 0 or near-zero, which is below the default 0.55 threshold.
        let provider = MockEmbeddingProvider(table: [
            "random gibberish": axis(3),       // axis 3 not in exemplars
            "what is my balance": axis(0),
            "my spending": axis(1),
        ])

        let exemplars: [ToolExemplar] = [
            .init(label: "account_balance", query: "what is my balance"),
            .init(label: "spending_summary", query: "my spending"),
        ]

        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: exemplars)

        let decision = await router.route(query: "random gibberish")
        if case .uncertain = decision {
            // Expected — pipeline will fall through to LLM planner
        } else {
            XCTFail("Expected .uncertain, got \(decision)")
        }
    }

    // MARK: Ambiguity

    func testRoute_closeToTwoLabels_returnsUncertain() async throws {
        // Construct a query equally close to two different labels.
        // With ambiguityMargin=0.03 (default), scores within 0.03 of
        // each other should trigger uncertain rather than picking one.
        let provider = MockEmbeddingProvider(table: [
            "ambiguous query": [0.7, 0.7, 0, 0],  // equal angle to axis 0 and axis 1
            "balance exemplar": axis(0),
            "spending exemplar": axis(1),
        ])

        let exemplars: [ToolExemplar] = [
            .init(label: "account_balance", query: "balance exemplar"),
            .init(label: "spending_summary", query: "spending exemplar"),
        ]

        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: exemplars)

        let decision = await router.route(query: "ambiguous query")
        if case .uncertain = decision {
            // Expected — both labels have identical ~0.707 score
        } else {
            XCTFail("Expected .uncertain for equidistant query, got \(decision)")
        }
    }

    // MARK: Args hint propagation

    func testRoute_propagatesArgsHint() async throws {
        // When "cash balance" wins, the returned Decision should carry
        // the exemplar's argsHint (e.g. scope=cash).
        let provider = MockEmbeddingProvider(table: [
            "cash in my account": axis(0),
            "my cash balance": axis(0),
            "my balance": [0, 1, 0, 0],  // different direction
        ])

        let exemplars: [ToolExemplar] = [
            .init(label: "account_balance", query: "my cash balance",
                  argsHint: ["scope": "cash"]),
            .init(label: "account_balance", query: "my balance"),
        ]

        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: exemplars)

        let decision = await router.route(query: "cash in my account")
        if case .tool(let name, let hint, _) = decision {
            XCTAssertEqual(name, "account_balance")
            XCTAssertEqual(hint["scope"], "cash", "Should pick the cash-scoped exemplar's hint")
        } else {
            XCTFail("Expected .tool decision, got \(decision)")
        }
    }

    // MARK: Graceful degradation

    func testRoute_providerFails_returnsUncertain() async throws {
        let provider = MockEmbeddingProvider(table: [
            "what is my balance": axis(0),
        ])

        let exemplars: [ToolExemplar] = [
            .init(label: "account_balance", query: "what is my balance"),
        ]

        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: exemplars)

        // Now fail the live query
        await provider.setFailOn(["breaking query"])

        let decision = await router.route(query: "breaking query")
        if case .uncertain = decision {
            // Expected — failure falls through to LLM, not an error
        } else {
            XCTFail("Embedding failure should produce .uncertain, got \(decision)")
        }
    }

    func testRoute_notReady_returnsUncertain() async throws {
        let provider = MockEmbeddingProvider(table: [:])
        let router = SemanticRouter(provider: provider)
        // NOT calling prewarm() — router should be unavailable

        let isAvailable = await router.isAvailable
        XCTAssertFalse(isAvailable)

        let decision = await router.route(query: "anything")
        if case .uncertain = decision {
            // Expected
        } else {
            XCTFail("Un-prewarmed router should return .uncertain, got \(decision)")
        }
    }

    func testRoute_emptyQuery_returnsUncertain() async throws {
        let provider = MockEmbeddingProvider(table: [
            "x": axis(0),
        ])
        let exemplars: [ToolExemplar] = [
            .init(label: "account_balance", query: "x"),
        ]

        let router = SemanticRouter(provider: provider)
        await router.prewarm(exemplars: exemplars)

        let decision = await router.route(query: "   ")
        if case .uncertain = decision {
            // Expected — empty query should not crash the pipeline
        } else {
            XCTFail("Empty query should return .uncertain, got \(decision)")
        }
    }

    // MARK: Threshold tuning

    func testRoute_customThresholds_respectsToolAccept() async throws {
        let provider = MockEmbeddingProvider(table: [
            "query": [0.5, 0.5, 0.5, 0.5],  // moderate similarity to axis 0 exemplar
            "balance": axis(0),
        ])
        let exemplars: [ToolExemplar] = [
            .init(label: "account_balance", query: "balance"),
        ]

        // With a strict threshold of 0.8, moderate similarity should fail
        var strict = SemanticRouter.Thresholds()
        strict.toolAccept = 0.8
        let strictRouter = SemanticRouter(provider: provider, thresholds: strict)
        await strictRouter.prewarm(exemplars: exemplars)

        let strictDecision = await strictRouter.route(query: "query")
        if case .uncertain = strictDecision {
            // Expected — 0.5 similarity is below 0.8 threshold
        } else {
            XCTFail("Strict threshold should reject moderate similarity, got \(strictDecision)")
        }

        // With a permissive threshold of 0.3, same similarity should pass
        var loose = SemanticRouter.Thresholds()
        loose.toolAccept = 0.3
        let looseRouter = SemanticRouter(provider: provider, thresholds: loose)
        await looseRouter.prewarm(exemplars: exemplars)

        let looseDecision = await looseRouter.route(query: "query")
        if case .tool = looseDecision {
            // Expected — 0.5 > 0.3
        } else {
            XCTFail("Loose threshold should accept moderate similarity, got \(looseDecision)")
        }
    }
}
