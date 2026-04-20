import Foundation
import HFDomain
import HFShared

// MARK: - SemanticRouter
//
// A lightweight, on-device intent router that maps free-text queries to
// tool names via embedding similarity. Sits between the greeting /
// out-of-scope keyword fast paths and the LLM planner in ToolPlanner.
//
// ARCHITECTURE
//   exemplars ──> [prewarmed cosine-normalized vectors]
//        │
//        ▼
//   query ──> embed(query) ──> top-k cosine ──> RouterDecision
//                                             │
//                                             ├─ .tool(name, argsHint, score)
//                                             ├─ .outOfScope(score)
//                                             └─ .uncertain (fall through)
//
// The router NEVER makes up tool names — every label comes from the seed
// ToolExemplars set, which is itself drawn from the ToolRegistry.
//
// FAILURE MODES
//   - Embedding backend unavailable: init returns a router that always
//     emits .uncertain, so the pipeline degrades gracefully to the LLM
//     planner / keyword heuristic path.
//   - Cold start accuracy: Phase 1 seed data covers ~10-15 queries per
//     tool. Accuracy climbs as the telemetry flywheel produces
//     training data and exemplar vectors are retrained/expanded.

public actor SemanticRouter {
    // MARK: - Types

    public struct Match: Sendable, Equatable {
        public let label: String
        public let query: String
        public let score: Float
        public let argsHint: [String: String]
    }

    /// Router output. `.tool` → use the tool; `.outOfScope` → refuse;
    /// `.uncertain` → fall through to the next planner stage.
    public enum Decision: Sendable, Equatable {
        case tool(name: String, argsHint: [String: String], confidence: Float)
        case outOfScope(confidence: Float)
        case uncertain(topLabel: String?, topScore: Float?)
    }

    /// Tunable thresholds. Kept as struct so callers can override for tests
    /// or per-user A/B experiments without touching the router code.
    public struct Thresholds: Sendable {
        /// Minimum cosine score to accept a tool match. Below this, router
        /// returns `.uncertain` so the LLM planner takes over.
        public var toolAccept: Float = 0.55
        /// Minimum cosine score to declare out-of-scope. OOS labels are
        /// inherently riskier (false positive = refusing a legitimate query),
        /// so we require higher confidence than for tool routing.
        public var oosAccept: Float = 0.65
        /// If the second-best label's score is within `ambiguityMargin` of
        /// the top, treat it as ambiguous (fall through to LLM). Prevents
        /// the router from choosing on a coin flip.
        public var ambiguityMargin: Float = 0.03

        public init() {}
    }

    // MARK: - State

    private let provider: any EmbeddingProvider
    private let thresholds: Thresholds

    /// Exemplars paired with their pre-normalized embedding vectors.
    /// Built once during `prewarm()` and never mutated — safe to read
    /// from any actor-isolated context.
    private var indexed: [(exemplar: ToolExemplar, vector: [Float])] = []
    private var isReady: Bool = false

    // MARK: - Init

    public init(
        provider: any EmbeddingProvider,
        thresholds: Thresholds = Thresholds()
    ) {
        self.provider = provider
        self.thresholds = thresholds
    }

    // MARK: - Lifecycle

    /// Embed all seed exemplars once and cache. Call from app startup so
    /// the first real query doesn't pay the warmup latency.
    public func prewarm(exemplars: [ToolExemplar] = ToolExemplars.all) async {
        guard !isReady else { return }
        var pairs: [(ToolExemplar, [Float])] = []
        pairs.reserveCapacity(exemplars.count)

        for ex in exemplars {
            do {
                let raw = try await provider.embed(ex.query)
                let norm = VectorMath.l2Normalized(raw)
                pairs.append((ex, norm))
            } catch {
                HFLogger.ai.warning("SemanticRouter: failed to embed exemplar '\(ex.query.prefix(40))': \(error.localizedDescription)")
            }
        }

        self.indexed = pairs
        self.isReady = !pairs.isEmpty
        HFLogger.ai.info("SemanticRouter prewarmed: \(pairs.count)/\(exemplars.count) exemplars indexed (provider=\(self.provider.providerId))")
    }

    /// Whether the router is ready to answer queries. Used by callers to
    /// decide whether to even invoke `route()`.
    public var isAvailable: Bool { isReady }

    // MARK: - Route

    /// Classify a query. Returns a `Decision` the ToolPlanner uses to
    /// decide whether to bypass the LLM.
    public func route(query: String) async -> Decision {
        guard isReady, !indexed.isEmpty else {
            return .uncertain(topLabel: nil, topScore: nil)
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .uncertain(topLabel: nil, topScore: nil)
        }

        let queryVec: [Float]
        do {
            let raw = try await provider.embed(trimmed)
            queryVec = VectorMath.l2Normalized(raw)
        } catch {
            HFLogger.ai.warning("SemanticRouter: embed failed for query, falling through: \(error.localizedDescription)")
            return .uncertain(topLabel: nil, topScore: nil)
        }

        // Compute top-2 for ambiguity detection. Linear scan is fine at
        // this scale (<500 vectors) — replace with approximate nearest
        // neighbor (HNSW, faiss) if exemplar count grows beyond ~10K.
        var top1: (Match)?
        var top2: (Match)?
        for (ex, vec) in indexed {
            let score = VectorMath.cosineNormalized(queryVec, vec)
            let match = Match(label: ex.label, query: ex.query, score: score, argsHint: ex.argsHint)
            if top1 == nil || score > top1!.score {
                top2 = top1
                top1 = match
            } else if top2 == nil || score > top2!.score {
                top2 = match
            }
        }

        guard let best = top1 else {
            return .uncertain(topLabel: nil, topScore: nil)
        }

        // Aggregate per-label best so top1 isn't dominated by one wordy
        // exemplar. We compute the best score *per unique label* and use
        // those to decide whether the top label's lead is robust across
        // multiple phrasings (less overfit to a single seed).
        var labelBest: [String: Float] = [:]
        for (ex, vec) in indexed {
            let s = VectorMath.cosineNormalized(queryVec, vec)
            if s > (labelBest[ex.label] ?? -.infinity) {
                labelBest[ex.label] = s
            }
        }
        // Sort descending by best-per-label
        let ranked = labelBest.sorted { $0.value > $1.value }
        let topLabelScore = ranked.first?.value ?? best.score
        let secondLabelScore = ranked.dropFirst().first?.value ?? -.infinity
        let topLabel = ranked.first?.key ?? best.label

        // Ambiguity check — if top-2 labels are very close, defer to LLM.
        if (topLabelScore - secondLabelScore) < thresholds.ambiguityMargin {
            HFLogger.ai.debug("SemanticRouter: ambiguous (\(topLabel)=\(topLabelScore), 2nd=\(secondLabelScore))")
            return .uncertain(topLabel: topLabel, topScore: topLabelScore)
        }

        if topLabel == OutOfScopeLabel {
            if topLabelScore >= thresholds.oosAccept {
                HFLogger.ai.info("SemanticRouter: OOS (score=\(topLabelScore))")
                return .outOfScope(confidence: topLabelScore)
            }
            return .uncertain(topLabel: topLabel, topScore: topLabelScore)
        }

        if topLabelScore >= thresholds.toolAccept {
            // Use the argsHint of the *specific* exemplar that had the
            // highest individual score for this label, not an arbitrary
            // one with the same label.
            let bestExemplar = indexed
                .map { (ex, vec) -> (ToolExemplar, Float) in
                    (ex, VectorMath.cosineNormalized(queryVec, vec))
                }
                .filter { $0.0.label == topLabel }
                .max { $0.1 < $1.1 }
                .map { $0.0 }

            let hint = bestExemplar?.argsHint ?? [:]
            HFLogger.ai.info("SemanticRouter: \(topLabel) (score=\(topLabelScore))")
            return .tool(name: topLabel, argsHint: hint, confidence: topLabelScore)
        }

        return .uncertain(topLabel: topLabel, topScore: topLabelScore)
    }
}
