import Foundation
import SwiftData
import HFDomain
import HFShared

public final class SwiftDataTelemetryEventRepository: TelemetryEventRepository, @unchecked Sendable {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    public func save(_ event: TelemetryEvent) async throws {
        let context = container.mainContext
        context.insert(SDTelemetryEvent(from: event))
        try context.save()
    }

    @MainActor
    public func updateFeedback(eventId: UUID, feedback: String?) async throws {
        let context = container.mainContext
        let target = eventId
        let descriptor = FetchDescriptor<SDTelemetryEvent>(predicate: #Predicate { $0.id == target })
        if let row = try context.fetch(descriptor).first {
            row.feedback = feedback
            // Re-queue so the updated feedback is uploaded on the next flush
            row.sent = false
            try context.save()
        }
    }

    @MainActor
    public func fetchUnsent(limit: Int) async throws -> [TelemetryEvent] {
        let context = container.mainContext
        var descriptor = FetchDescriptor<SDTelemetryEvent>(
            predicate: #Predicate { $0.sent == false && $0.attempts < 5 },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    @MainActor
    public func markSent(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let context = container.mainContext
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<SDTelemetryEvent>(predicate: #Predicate { idSet.contains($0.id) })
        for row in try context.fetch(descriptor) {
            row.sent = true
        }
        try context.save()
    }

    @MainActor
    public func incrementAttempts(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let context = container.mainContext
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<SDTelemetryEvent>(predicate: #Predicate { idSet.contains($0.id) })
        for row in try context.fetch(descriptor) {
            row.attempts += 1
        }
        try context.save()
    }

    @MainActor
    public func purgeAll() async throws {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDTelemetryEvent>()
        for row in try context.fetch(descriptor) {
            context.delete(row)
        }
        try context.save()
        HFLogger.telemetry.info("SwiftDataTelemetryEventRepository: purged all events")
    }

    @MainActor
    public func purgeMaxAttempts(threshold: Int) async throws {
        let context = container.mainContext
        let limit = threshold
        let descriptor = FetchDescriptor<SDTelemetryEvent>(predicate: #Predicate { $0.attempts >= limit })
        let rows = try context.fetch(descriptor)
        let count = rows.count
        for row in rows {
            context.delete(row)
        }
        if count > 0 {
            try context.save()
            HFLogger.telemetry.warning("SwiftDataTelemetryEventRepository: purged \(count) events at max attempts")
        }
    }
}
