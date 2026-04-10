import Foundation
import HFShared

extension APIClient {
    /// Open an SSE stream to `path` and yield each text delta the server emits.
    ///
    /// The server is expected to follow the loose "data: <json>\n\n" SSE format
    /// used by the cloud chat route: each `data:` line holds a JSON object with
    /// a `delta` string field, and the terminal sentinel is `data: [DONE]`.
    /// Any line whose payload is `{"error": "..."}` causes the stream to finish
    /// with an `APIError.httpError`.
    ///
    /// The yielded values are **per-chunk deltas**, not cumulative text — the
    /// caller (`CloudInferenceEngine`) is responsible for accumulating if it
    /// wants to match the local `InferenceEngine` cumulative semantics.
    public func stream(
        path: String,
        body: Encodable,
        installId: String
    ) -> AsyncThrowingStream<String, Error> {
        // Encode the body *before* entering the nested task so only Sendable
        // values (Data, String) cross the task boundary. This sidesteps the
        // Swift 6 "sending closure" diagnostic for the non-Sendable Encodable.
        let baseURL = self.baseURL
        let session = self.session
        let encodedBody: Data
        do {
            encodedBody = try self.encoder.encode(body)
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(baseURL)/\(HFConstants.API.apiVersion)/\(path)") else {
                        throw APIError.invalidURL
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = HFConstants.API.cloudChatTimeoutInterval
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(installId, forHTTPHeaderField: "X-Install-Id")
                    request.httpBody = encodedBody

                    HFLogger.cloudChat.debug("POST \(path) (stream)")

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch {
                        throw APIError.networkError(error)
                    }

                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.networkError(URLError(.badServerResponse))
                    }

                    if http.statusCode == 401 {
                        throw APIError.unauthorized
                    }

                    guard (200...299).contains(http.statusCode) else {
                        // Best-effort body read for the error surface
                        var buf = ""
                        for try await line in bytes.lines { buf += line + "\n"; if buf.count > 4096 { break } }
                        throw APIError.httpError(statusCode: http.statusCode, body: buf.isEmpty ? nil : buf)
                    }

                    for try await rawLine in bytes.lines {
                        if Task.isCancelled { break }
                        // SSE frames are separated by blank lines; bytes.lines
                        // already yields individual lines so we just look at
                        // the `data:` prefix.
                        guard rawLine.hasPrefix("data:") else { continue }
                        let payload = rawLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let frame = try? JSONDecoder().decode(StreamFrame.self, from: data) {
                            if let errorMessage = frame.error {
                                throw APIError.httpError(statusCode: 500, body: errorMessage)
                            }
                            if let delta = frame.delta, !delta.isEmpty {
                                continuation.yield(delta)
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

private struct StreamFrame: Decodable {
    let delta: String?
    let error: String?
}
