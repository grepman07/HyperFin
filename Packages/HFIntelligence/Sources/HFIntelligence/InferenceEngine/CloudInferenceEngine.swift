import Foundation
import HFNetworking
import HFShared

/// Cloud inference engine backed by the server-side `/v1/chat/stream` proxy to
/// Claude Haiku. Mirrors the public surface of `InferenceEngine` so the
/// `ChatEngine` can swap between the local and cloud path without any other
/// changes. Like the local engine, `generate(_:)` yields **cumulative text**
/// (each yielded value is the full response so far), so existing consumers
/// like `ChatViewModel.streamFromEngine` stay identical.
///
/// Privacy note: this engine is only wired up when the user has opted in via
/// `UserProfile.cloudChatOptIn`. The only data that ever reaches the cloud is
/// the already-assembled prompt (anonymized user query + pre-aggregated tool
/// result JSON). Retrieval is 100% local regardless of this flag.
public actor CloudInferenceEngine {
    private let apiClient: APIClient
    private let installId: String

    public init(apiClient: APIClient, installId: String) {
        self.apiClient = apiClient
        self.installId = installId
    }

    public func generate(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        let client = self.apiClient
        let iid = self.installId

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = CloudChatRequest(
                        prompt: request.prompt,
                        maxTokens: request.maxTokens,
                        temperature: request.temperature
                    )
                    let stream = await client.stream(
                        path: HFConstants.API.cloudChatStreamPath,
                        body: body,
                        installId: iid
                    )
                    var fullText = ""
                    for try await delta in stream {
                        if Task.isCancelled { break }
                        fullText += delta
                        // Cumulative semantics — match InferenceEngine exactly.
                        continuation.yield(fullText)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    HFLogger.cloudChat.error("Cloud inference failed: \(String(describing: error))")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func generateComplete(_ request: InferenceRequest) async throws -> String {
        var result = ""
        for try await token in generate(request) {
            result = token
        }
        return result
    }
}

private struct CloudChatRequest: Encodable, Sendable {
    let prompt: String
    let maxTokens: Int
    let temperature: Float
}
