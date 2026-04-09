import Foundation

/// Abstraction over telemetry uploads. Lives in HFDomain so TelemetryLogger
/// (HFIntelligence) can depend on it without pulling in HFNetworking.
public protocol TelemetryUploading: Sendable {
    /// Upload a batch of anonymized events. Throws on any non-2xx response.
    func upload(batch: [TelemetryEvent]) async throws
    /// Request server-side deletion of all events for the given install ID.
    func deleteAll(installId: String) async throws
}

/// Persists anonymized telemetry events locally (SwiftData) until they are
/// uploaded in batches. Implementations must be safe for concurrent access.
public protocol TelemetryEventRepository: Sendable {
    /// Insert a new event. Called from TelemetryLogger after anonymization.
    func save(_ event: TelemetryEvent) async throws

    /// Update the feedback field on an existing event (thumbs up/down).
    func updateFeedback(eventId: UUID, feedback: String?) async throws

    /// Return unsent events ordered oldest-first, up to `limit`.
    func fetchUnsent(limit: Int) async throws -> [TelemetryEvent]

    /// Mark the given events as successfully uploaded.
    func markSent(ids: [UUID]) async throws

    /// Increment retry counter for events whose batch failed upload.
    func incrementAttempts(ids: [UUID]) async throws

    /// Delete every stored event (used on opt-out).
    func purgeAll() async throws

    /// Delete events whose attempt count meets or exceeds `threshold`.
    func purgeMaxAttempts(threshold: Int) async throws
}
