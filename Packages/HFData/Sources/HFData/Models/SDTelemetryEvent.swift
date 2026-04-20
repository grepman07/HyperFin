import Foundation
import SwiftData
import HFDomain

/// SwiftData-backed local queue for anonymized telemetry events. Rows sit here
/// until `TelemetryLogger.flushPending()` uploads them and calls `markSent`.
/// `sent == false && attempts < 5` → eligible for next upload batch.
@Model
public final class SDTelemetryEvent {
    @Attribute(.unique) public var id: UUID
    public var installId: String
    public var sessionId: UUID
    public var timestamp: Date
    public var queryAnon: String
    public var responseAnon: String
    public var intent: String
    public var category: String?
    public var period: String?
    public var latencyMs: Int
    public var modelVersion: String
    public var appVersion: String
    public var feedback: String?
    public var sent: Bool = false
    public var attempts: Int = 0
    /// Raw plan JSON from the planner for shadow-eval pipeline. Optional
    /// with default "" for migration compatibility — SwiftData requires
    /// defaults for new properties added to existing stores.
    public var planJSON: String = ""
    /// Routing tier that produced the plan (semantic/llm/heuristic/etc).
    public var planSource: String = ""

    public init(from domain: TelemetryEvent) {
        self.id = domain.id
        self.installId = domain.installId
        self.sessionId = domain.sessionId
        self.timestamp = domain.timestamp
        self.queryAnon = domain.queryAnon
        self.responseAnon = domain.responseAnon
        self.intent = domain.intent
        self.category = domain.category
        self.period = domain.period
        self.latencyMs = domain.latencyMs
        self.modelVersion = domain.modelVersion
        self.appVersion = domain.appVersion
        self.feedback = domain.feedback
        self.sent = false
        self.attempts = 0
        self.planJSON = domain.planJSON ?? ""
        self.planSource = domain.planSource ?? ""
    }

    public func toDomain() -> TelemetryEvent {
        TelemetryEvent(
            id: id,
            installId: installId,
            sessionId: sessionId,
            timestamp: timestamp,
            queryAnon: queryAnon,
            responseAnon: responseAnon,
            intent: intent,
            category: category,
            period: period,
            latencyMs: latencyMs,
            modelVersion: modelVersion,
            appVersion: appVersion,
            feedback: feedback,
            planJSON: planJSON.isEmpty ? nil : planJSON,
            planSource: planSource.isEmpty ? nil : planSource
        )
    }
}
