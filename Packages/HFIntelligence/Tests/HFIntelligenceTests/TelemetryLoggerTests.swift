import XCTest
import HFDomain
@testable import HFIntelligence

// MARK: - Mocks

final class MockTelemetryRepo: TelemetryEventRepository, @unchecked Sendable {
    var events: [UUID: TelemetryEvent] = [:]
    var attempts: [UUID: Int] = [:]
    var sent: Set<UUID> = []
    var saveCount = 0
    var purgeCount = 0

    func save(_ event: TelemetryEvent) async throws {
        events[event.id] = event
        attempts[event.id] = 0
        saveCount += 1
    }

    func updateFeedback(eventId: UUID, feedback: String?) async throws {
        guard var e = events[eventId] else { return }
        e.feedback = feedback
        events[eventId] = e
        sent.remove(eventId) // re-queue
    }

    func fetchUnsent(limit: Int) async throws -> [TelemetryEvent] {
        let unsent = events.values.filter { !sent.contains($0.id) && (attempts[$0.id] ?? 0) < 5 }
        return Array(unsent.prefix(limit))
    }

    func markSent(ids: [UUID]) async throws {
        for id in ids { sent.insert(id) }
    }

    func incrementAttempts(ids: [UUID]) async throws {
        for id in ids { attempts[id, default: 0] += 1 }
    }

    func purgeAll() async throws {
        events.removeAll()
        attempts.removeAll()
        sent.removeAll()
        purgeCount += 1
    }

    func purgeMaxAttempts(threshold: Int) async throws {
        for (id, count) in attempts where count >= threshold {
            events.removeValue(forKey: id)
            attempts.removeValue(forKey: id)
            sent.remove(id)
        }
    }
}

final class MockUploader: TelemetryUploading, @unchecked Sendable {
    var shouldFail = false
    var uploadedBatches: [[TelemetryEvent]] = []
    var deleteAllCalls: [String] = []

    func upload(batch: [TelemetryEvent]) async throws {
        if shouldFail { throw NSError(domain: "mock", code: 500) }
        uploadedBatches.append(batch)
    }

    func deleteAll(installId: String) async throws {
        deleteAllCalls.append(installId)
    }
}

// MARK: - Tests

final class TelemetryLoggerTests: XCTestCase {

    private func makeLogger(
        repo: MockTelemetryRepo,
        uploader: MockUploader,
        optedIn: Bool = true,
        userName: String? = "Kevin"
    ) -> TelemetryLogger {
        TelemetryLogger(
            repo: repo,
            uploader: uploader,
            installId: "install-abc",
            appVersion: "1.0.0",
            modelVersion: "test-model",
            isOptedInProvider: { optedIn },
            userNameProvider: { userName }
        )
    }

    func testLogRespectsOptOut() async {
        let repo = MockTelemetryRepo()
        let uploader = MockUploader()
        let logger = makeLogger(repo: repo, uploader: uploader, optedIn: false)

        let id = await logger.log(
            queryRaw: "hi",
            responseRaw: "hello",
            intent: "greeting",
            category: nil,
            period: nil,
            latencyMs: 100,
            sessionId: UUID()
        )

        XCTAssertNil(id)
        XCTAssertEqual(repo.saveCount, 0)
    }

    func testLogAnonymizesBeforePersisting() async throws {
        let repo = MockTelemetryRepo()
        let uploader = MockUploader()
        let logger = makeLogger(repo: repo, uploader: uploader)

        let id = await logger.log(
            queryRaw: "How much did Kevin spend on Uber?",
            responseRaw: "Kevin spent $142.50",
            intent: "spending",
            category: nil,
            period: "this_month",
            latencyMs: 200,
            sessionId: UUID()
        )

        XCTAssertNotNil(id)
        XCTAssertEqual(repo.saveCount, 1)
        let stored = try XCTUnwrap(repo.events[id!])
        XCTAssertEqual(stored.queryAnon, "How much did [NAME] spend on Uber?")
        XCTAssertEqual(stored.responseAnon, "[NAME] spent $142.50")
        XCTAssertEqual(stored.intent, "spending")
        XCTAssertEqual(stored.period, "this_month")
    }

    func testUpdateFeedbackStoresString() async throws {
        let repo = MockTelemetryRepo()
        let uploader = MockUploader()
        let logger = makeLogger(repo: repo, uploader: uploader)

        let id = await logger.log(
            queryRaw: "q", responseRaw: "r", intent: "spending",
            category: nil, period: nil, latencyMs: 10, sessionId: UUID()
        )
        await logger.updateFeedback(eventId: id!, rating: .positive)

        XCTAssertEqual(repo.events[id!]?.feedback, "positive")
    }

    func testFlushUploadsBatchAndMarksSent() async throws {
        let repo = MockTelemetryRepo()
        let uploader = MockUploader()
        let logger = makeLogger(repo: repo, uploader: uploader)

        for i in 0..<3 {
            _ = await logger.log(
                queryRaw: "q\(i)", responseRaw: "r\(i)", intent: "spending",
                category: nil, period: nil, latencyMs: 10, sessionId: UUID()
            )
        }

        await logger.flushPending()

        XCTAssertEqual(uploader.uploadedBatches.count, 1)
        XCTAssertEqual(uploader.uploadedBatches.first?.count, 3)
        XCTAssertEqual(repo.sent.count, 3)
    }

    func testFlushThrottled() async throws {
        let repo = MockTelemetryRepo()
        let uploader = MockUploader()
        let logger = makeLogger(repo: repo, uploader: uploader)

        _ = await logger.log(
            queryRaw: "q", responseRaw: "r", intent: "spending",
            category: nil, period: nil, latencyMs: 10, sessionId: UUID()
        )
        await logger.flushPending()
        XCTAssertEqual(uploader.uploadedBatches.count, 1)

        // Second flush right away should be throttled
        _ = await logger.log(
            queryRaw: "q2", responseRaw: "r2", intent: "spending",
            category: nil, period: nil, latencyMs: 10, sessionId: UUID()
        )
        await logger.flushPending()
        XCTAssertEqual(uploader.uploadedBatches.count, 1, "throttled flush must not upload")
    }

    func testFlushFailureIncrementsAttempts() async throws {
        let repo = MockTelemetryRepo()
        let uploader = MockUploader()
        uploader.shouldFail = true
        let logger = makeLogger(repo: repo, uploader: uploader)

        let id = await logger.log(
            queryRaw: "q", responseRaw: "r", intent: "spending",
            category: nil, period: nil, latencyMs: 10, sessionId: UUID()
        )
        await logger.flushPending()

        XCTAssertEqual(repo.attempts[id!], 1)
        XCTAssertFalse(repo.sent.contains(id!))
    }

    func testFlushRespectsOptOut() async {
        let repo = MockTelemetryRepo()
        let uploader = MockUploader()
        let logger = makeLogger(repo: repo, uploader: uploader, optedIn: false)

        await logger.flushPending()
        XCTAssertEqual(uploader.uploadedBatches.count, 0)
    }

    func testPurgeLocalQueueCallsRepoAndServer() async {
        let repo = MockTelemetryRepo()
        let uploader = MockUploader()
        let logger = makeLogger(repo: repo, uploader: uploader)

        _ = await logger.log(
            queryRaw: "q", responseRaw: "r", intent: "spending",
            category: nil, period: nil, latencyMs: 10, sessionId: UUID()
        )

        await logger.purgeLocalQueue()

        XCTAssertEqual(repo.purgeCount, 1)
        XCTAssertEqual(repo.events.count, 0)
        XCTAssertEqual(uploader.deleteAllCalls, ["install-abc"])
    }
}
