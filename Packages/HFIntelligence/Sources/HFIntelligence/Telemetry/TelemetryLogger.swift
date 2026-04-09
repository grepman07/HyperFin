import Foundation
import HFDomain
import HFShared

/// Feedback rating mirrored from the UI layer so TelemetryLogger can map it
/// to the "positive" / "negative" / nil strings stored on TelemetryEvent.
public enum TelemetryFeedbackRating: String, Sendable {
    case positive
    case negative
    case none
}

/// Serializes anonymization, persistence, and upload of chat telemetry.
/// Every public method is a no-op when `isOptedInProvider()` returns false,
/// so it is safe to call unconditionally from the UI layer.
public actor TelemetryLogger {
    public typealias OptInProvider = @Sendable () async -> Bool
    public typealias UserNameProvider = @Sendable () async -> String?

    private let repo: TelemetryEventRepository
    private let uploader: TelemetryUploading
    private let installId: String
    private let appVersion: String
    private let modelVersion: String
    private let isOptedInProvider: OptInProvider
    private let userNameProvider: UserNameProvider

    private var lastFlush: Date = .distantPast

    public init(
        repo: TelemetryEventRepository,
        uploader: TelemetryUploading,
        installId: String,
        appVersion: String,
        modelVersion: String,
        isOptedInProvider: @escaping OptInProvider,
        userNameProvider: @escaping UserNameProvider
    ) {
        self.repo = repo
        self.uploader = uploader
        self.installId = installId
        self.appVersion = appVersion
        self.modelVersion = modelVersion
        self.isOptedInProvider = isOptedInProvider
        self.userNameProvider = userNameProvider
    }

    // MARK: - Logging

    /// Anonymize, persist, and return the event ID so the caller can later
    /// attach feedback. Returns nil if the user has not opted in.
    @discardableResult
    public func log(
        queryRaw: String,
        responseRaw: String,
        intent: String,
        category: String?,
        period: String?,
        latencyMs: Int,
        sessionId: UUID
    ) async -> UUID? {
        guard await isOptedInProvider() else {
            return nil
        }

        let userName = await userNameProvider()
        let queryAnon = Anonymizer.anonymize(text: queryRaw, userName: userName)
        let responseAnon = Anonymizer.anonymize(text: responseRaw, userName: userName)

        let event = TelemetryEvent(
            installId: installId,
            sessionId: sessionId,
            queryAnon: queryAnon,
            responseAnon: responseAnon,
            intent: intent,
            category: category,
            period: period,
            latencyMs: latencyMs,
            modelVersion: modelVersion,
            appVersion: appVersion,
            feedback: nil
        )

        do {
            try await repo.save(event)
            HFLogger.telemetry.debug("TelemetryLogger: logged event \(event.id.uuidString.prefix(8)) intent=\(intent)")
            return event.id
        } catch {
            HFLogger.telemetry.error("TelemetryLogger: save failed: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Feedback

    public func updateFeedback(eventId: UUID, rating: TelemetryFeedbackRating) async {
        guard await isOptedInProvider() else { return }
        let value: String? = switch rating {
        case .positive: "positive"
        case .negative: "negative"
        case .none: nil
        }
        do {
            try await repo.updateFeedback(eventId: eventId, feedback: value)
            HFLogger.telemetry.debug("TelemetryLogger: feedback \(rating.rawValue) for \(eventId.uuidString.prefix(8))")
        } catch {
            HFLogger.telemetry.error("TelemetryLogger: updateFeedback failed: \(String(describing: error))")
        }
    }

    // MARK: - Flush

    /// Upload the oldest batch of unsent events. Rate-limited: no-op if the
    /// previous call was less than `minFlushGap` seconds ago. Respects opt-in.
    public func flushPending() async {
        guard await isOptedInProvider() else { return }

        let now = Date()
        if now.timeIntervalSince(lastFlush) < HFConstants.Telemetry.minFlushGapSeconds {
            HFLogger.telemetry.debug("TelemetryLogger: flush throttled")
            return
        }
        lastFlush = now

        // Drop events that have already failed too many times
        try? await repo.purgeMaxAttempts(threshold: HFConstants.Telemetry.maxAttempts)

        let batch: [TelemetryEvent]
        do {
            batch = try await repo.fetchUnsent(limit: HFConstants.Telemetry.batchSize)
        } catch {
            HFLogger.telemetry.error("TelemetryLogger: fetchUnsent failed: \(String(describing: error))")
            return
        }

        guard !batch.isEmpty else {
            HFLogger.telemetry.debug("TelemetryLogger: nothing to flush")
            return
        }

        HFLogger.telemetry.info("TelemetryLogger: flushing \(batch.count) events")
        let ids = batch.map(\.id)

        do {
            try await uploader.upload(batch: batch)
            try await repo.markSent(ids: ids)
            HFLogger.telemetry.info("TelemetryLogger: flush succeeded (\(batch.count))")
        } catch {
            HFLogger.telemetry.warning("TelemetryLogger: upload failed, incrementing attempts: \(String(describing: error))")
            try? await repo.incrementAttempts(ids: ids)
        }
    }

    // MARK: - Purge (opt-out)

    /// Called when the user toggles telemetry OFF. Wipes the local queue and
    /// asks the server to delete all events for this install ID.
    public func purgeLocalQueue() async {
        do {
            try await repo.purgeAll()
            HFLogger.telemetry.info("TelemetryLogger: local queue purged")
        } catch {
            HFLogger.telemetry.error("TelemetryLogger: purge failed: \(String(describing: error))")
        }

        do {
            try await uploader.deleteAll(installId: installId)
        } catch {
            HFLogger.telemetry.warning("TelemetryLogger: server delete request failed (will retry on next opt-in cycle): \(String(describing: error))")
        }
    }
}
