import Foundation

/// Anonymized chat telemetry event captured locally and uploaded in batches
/// (only when the user has explicitly opted in). Queries and responses are
/// redacted via `Anonymizer` in HFShared BEFORE being written to disk, so the
/// queryAnon/responseAnon fields on this struct never contain raw PII.
public struct TelemetryEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let installId: String          // stable random UUID, from Keychain
    public let sessionId: UUID            // per chat session
    public let timestamp: Date
    public let queryAnon: String          // anonymized user query
    public let responseAnon: String       // anonymized assistant response
    public let intent: String             // "spending", "budget", "balance", "trend", "anomaly", "advice", "greeting", "unknown"
    public let category: String?
    public let period: String?
    public let latencyMs: Int
    public let modelVersion: String
    public let appVersion: String
    public var feedback: String?          // "positive" | "negative" | nil

    // MARK: - Data flywheel fields (Change 4)
    //
    // These enable server-side shadow evaluation: feed `queryAnon` to a
    // superior cloud model, compare its JSON output to `planJSON`, derive
    // training pairs, fine-tune the semantic router. `planSource` tells
    // the analysis which routing tier answered (semantic, llm, heuristic,
    // unsupported) so we can track each tier's accuracy independently.

    /// Raw JSON output from the planner for this turn, before execution.
    /// Empty string when the turn was a canned reply (greeting, unsupported
    /// via keyword) so no planning actually ran. Nil on events produced
    /// before this field existed (backward compat with queue on disk).
    public let planJSON: String?

    /// Which routing tier produced the plan: "semantic" | "llm" |
    /// "heuristic" | "unsupported" | "empty". Nil on legacy events.
    public let planSource: String?

    public init(
        id: UUID = UUID(),
        installId: String,
        sessionId: UUID,
        timestamp: Date = Date(),
        queryAnon: String,
        responseAnon: String,
        intent: String,
        category: String? = nil,
        period: String? = nil,
        latencyMs: Int,
        modelVersion: String,
        appVersion: String,
        feedback: String? = nil,
        planJSON: String? = nil,
        planSource: String? = nil
    ) {
        self.id = id
        self.installId = installId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.queryAnon = queryAnon
        self.responseAnon = responseAnon
        self.intent = intent
        self.category = category
        self.period = period
        self.latencyMs = latencyMs
        self.modelVersion = modelVersion
        self.appVersion = appVersion
        self.feedback = feedback
        self.planJSON = planJSON
        self.planSource = planSource
    }
}
