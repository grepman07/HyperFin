import Foundation
import HFDomain
import HFShared

/// Wraps the existing `APIClient` for telemetry endpoints. Payload shape
/// matches the Zod schema defined in `Server/src/routes/telemetry.ts`.
/// Conforms to `TelemetryUploading` (defined in HFDomain).
public struct TelemetryService: TelemetryUploading {
    private let apiClient: APIClient

    public init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    public func upload(batch: [TelemetryEvent]) async throws {
        guard !batch.isEmpty else { return }
        let payload = TelemetryUploadRequest(events: batch)
        let _: TelemetryUploadResponse = try await apiClient.post(
            path: "telemetry/events",
            body: payload
        )
        HFLogger.telemetry.info("TelemetryService: uploaded \(batch.count) events")
    }

    public func deleteAll(installId: String) async throws {
        let payload = TelemetryDeleteRequest(installId: installId)
        let _: TelemetryUploadResponse = try await apiClient.post(
            path: "telemetry/delete",
            body: payload
        )
        HFLogger.telemetry.info("TelemetryService: delete-all requested")
    }
}

// MARK: - Wire payloads

public struct TelemetryUploadRequest: Codable, Sendable {
    public let events: [TelemetryEvent]
    public init(events: [TelemetryEvent]) {
        self.events = events
    }
}

public struct TelemetryDeleteRequest: Codable, Sendable {
    public let installId: String
    public init(installId: String) {
        self.installId = installId
    }
}

public struct TelemetryUploadResponse: Codable, Sendable {
    public let accepted: Int
    public init(accepted: Int) {
        self.accepted = accepted
    }
}
