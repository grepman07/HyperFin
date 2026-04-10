import Foundation
import HFDomain
import HFShared

#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
#endif

public struct InferenceRequest: Sendable {
    public let prompt: String
    public let messages: [StructuredMessage]?
    public let maxTokens: Int
    public let temperature: Float

    public init(
        prompt: String,
        maxTokens: Int = HFConstants.AI.maxGenerationTokens,
        temperature: Float = HFConstants.AI.temperature
    ) {
        self.prompt = prompt
        self.messages = nil
        self.maxTokens = maxTokens
        self.temperature = temperature
    }

    public init(
        messages: [StructuredMessage],
        maxTokens: Int = HFConstants.AI.maxGenerationTokens,
        temperature: Float = HFConstants.AI.temperature
    ) {
        self.messages = messages
        // Flatten messages into a plain prompt string as fallback for
        // engines that don't support structured messages (e.g. cloud).
        self.prompt = messages.map { msg in
            switch msg.role {
            case .system: return "[System]\n\(msg.content)"
            case .user: return "[User]\n\(msg.content)"
            case .assistant: return "[Assistant]\n\(msg.content)"
            }
        }.joined(separator: "\n\n")
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

// MARK: - Model Token Config

public struct ModelTokenConfig: Sendable {
    public let stopTokens: [String]
    public let stripTokens: [String]

    public static let qwen = ModelTokenConfig(
        stopTokens: ["<|im_end|>", "<|endoftext|>"],
        stripTokens: ["<|im_start|>", "<|im_end|>", "<|endoftext|>"]
    )

    public static let gemma = ModelTokenConfig(
        stopTokens: ["<end_of_turn>", "<eos>"],
        stripTokens: ["<start_of_turn>", "<end_of_turn>", "<eos>"]
    )
}

// MARK: - Inference Engine

public actor InferenceEngine {
    private let modelManager: ModelManager
    private let tokenConfig: ModelTokenConfig

    public init(modelManager: ModelManager, tokenConfig: ModelTokenConfig = .qwen) {
        self.modelManager = modelManager
        self.tokenConfig = tokenConfig
    }

    public func generate(_ request: InferenceRequest) -> AsyncThrowingStream<String, Error> {
        #if canImport(MLXLLM) && !targetEnvironment(simulator)
        let manager = self.modelManager
        let config = self.tokenConfig
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await manager.acquireInference()

                    guard await manager.isLoaded else {
                        await manager.releaseInference()
                        continuation.yield("[Model not loaded]")
                        continuation.finish()
                        return
                    }

                    guard let container = await manager.getContainer() else {
                        await manager.releaseInference()
                        continuation.finish(throwing: ModelError.modelNotLoaded)
                        return
                    }

                    HFLogger.ai.debug("Starting MLX inference (\(request.maxTokens) max tokens)")

                    // Build the LMInput from either structured messages (preferred)
                    // or a raw prompt string (legacy/cloud fallback).
                    //
                    // When structured messages are available, we use UserInput(chat:)
                    // which passes role-tagged messages to the tokenizer's
                    // applyChatTemplate — applying the model's ChatML format
                    // EXACTLY ONCE. This eliminates the double-wrapping bug where
                    // PromptAssembler manually wrote <|im_start|>/<|im_end|> markers,
                    // then UserInput(prompt:) wrapped them as a user message, and
                    // applyChatTemplate added a second layer of markers, causing
                    // the model to echo the inner markers as literal text.
                    let lmInput: LMInput
                    if let messages = request.messages {
                        let chatMessages: [Chat.Message] = messages.map { msg in
                            switch msg.role {
                            case .system: return .system(msg.content)
                            case .user: return .user(msg.content)
                            case .assistant: return .assistant(msg.content)
                            }
                        }
                        lmInput = try await container.prepare(
                            input: UserInput(chat: chatMessages)
                        )
                    } else {
                        lmInput = try await container.prepare(
                            input: UserInput(prompt: request.prompt)
                        )
                    }

                    let parameters = GenerateParameters(temperature: request.temperature)
                    let stream = try await container.generate(input: lmInput, parameters: parameters)

                    var tokenCount = 0
                    var fullText = ""
                    var shouldStop = false
                    for await generation in stream {
                        if shouldStop { break }
                        switch generation {
                        case .chunk(let text):
                            tokenCount += 1
                            if tokenCount > request.maxTokens { break }

                            // Accumulate the raw delta, then run stop-detection
                            // and stripping on the ACCUMULATED buffer — not
                            // just this chunk. Qwen 2.5's `<|im_end|>` arrives
                            // as multiple decoded sub-token fragments (e.g.
                            // `<|im_`, `end`, `|>`) when the prompt bypasses
                            // the tokenizer's chat template path. Checking a
                            // single chunk with `text.contains("<|im_end|>")`
                            // never matches any individual fragment, so the
                            // marker leaks into the UI. Checking the running
                            // `fullText` catches the cross-chunk case.
                            fullText += text

                            // Stop-check FIRST, before stripping. Stripping
                            // would remove `<|im_end|>` from the buffer and
                            // silently swallow the end-of-turn signal, causing
                            // the model to keep generating past where it
                            // intended to stop.
                            if let stopRange = config.stopTokens
                                .compactMap({ fullText.range(of: $0) })
                                .min(by: { $0.lowerBound < $1.lowerBound }) {
                                fullText = String(fullText[..<stopRange.lowerBound])
                                continuation.yield(Self.sanitize(fullText, config: config))
                                shouldStop = true
                                break
                            }

                            // No complete stop token yet. Yield a sanitized
                            // view of the accumulated buffer. Sanitize handles
                            // three concerns in order:
                            //   1. Remove any fully-formed control markers
                            //      that appeared inline (stripTokens).
                            //   2. Suppress any trailing PARTIAL stop-token
                            //      prefix at the tail (e.g. `<|im_end` with
                            //      the closing `|>` still in flight). This
                            //      is the critical fix: without it, a buffer
                            //      like "Hello<|im_" flashes to the UI and
                            //      stays visible if MLX ends the stream
                            //      before emitting the closing fragment.
                            //   3. Return a DISPLAY COPY — we keep the raw
                            //      partial bytes in `fullText` so the next
                            //      iteration's stop-check can still fire
                            //      once the closing fragment arrives.
                            continuation.yield(Self.sanitize(fullText, config: config))

                        case .info(let info):
                            HFLogger.ai.debug("Inference complete: \(info.promptTokenCount) prompt tokens, \(String(format: "%.1f", info.tokensPerSecond)) tok/s")

                        default:
                            break
                        }
                    }

                    // Belt-and-suspenders final cleanup: if the stream ended
                    // naturally with a trailing partial stop-token fragment
                    // (MLX sometimes stops generation mid-marker when the
                    // special token is recognized internally before all its
                    // decoded bytes are flushed), emit one last sanitized
                    // yield so the UI lands on a clean final state instead
                    // of a dangling `<|im_end`.
                    if !shouldStop {
                        let finalText = Self.sanitize(fullText, config: config)
                        continuation.yield(finalText)
                    }

                    await manager.releaseInference()
                    continuation.finish()
                } catch {
                    await manager.releaseInference()
                    HFLogger.ai.error("Inference failed: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
        #else
        return AsyncThrowingStream { continuation in
            continuation.yield("[AI engine requires a physical device with Apple Silicon]")
            continuation.finish()
        }
        #endif
    }

    public func generateComplete(_ request: InferenceRequest) async throws -> String {
        var result = ""
        for try await token in generate(request) {
            result = token
        }
        return result
    }

    /// Produce a display-safe view of the accumulated generation buffer.
    ///
    /// 1. Removes every fully-formed control marker inline (e.g. a stray
    ///    `<|im_start|>` mid-response).
    /// 2. Suppresses a trailing PARTIAL stop-token prefix — the characters
    ///    at the tail of `text` that match the beginning of any stop token.
    ///    Example: with Qwen stop token `<|im_end|>`, the tail `"...<|im_end"`
    ///    is truncated to `"..."` because it's a real suffix of the stop
    ///    marker. Without this the UI briefly shows `<|im_end` before the
    ///    next chunk arrives, and if the stream terminates there the partial
    ///    marker stays visible permanently.
    ///
    /// Returns a fresh string — does NOT mutate the raw buffer, because the
    /// caller still needs the unredacted tail to run full stop-token
    /// detection on the next chunk.
    nonisolated static func sanitize(_ text: String, config: ModelTokenConfig) -> String {
        var result = text
        for token in config.stripTokens {
            result = result.replacingOccurrences(of: token, with: "")
        }
        // Walk each stop token and check whether any non-empty prefix of it
        // is a suffix of the buffer. Use the longest such prefix so a tail
        // like `"<|im_end"` matches the 8-char prefix of `"<|im_end|>"`
        // rather than the 1-char prefix `"<"`.
        var longestPartialLength = 0
        for stop in config.stopTokens {
            // Start at length-1 and walk down to find the longest prefix.
            // max practical stop token length is ~20 chars, so this is O(n).
            let maxLen = min(stop.count - 1, result.count)
            if maxLen <= 0 { continue }
            for len in stride(from: maxLen, through: 1, by: -1) {
                let prefix = String(stop.prefix(len))
                if result.hasSuffix(prefix) {
                    if len > longestPartialLength { longestPartialLength = len }
                    break
                }
            }
        }
        if longestPartialLength > 0 {
            result = String(result.dropLast(longestPartialLength))
        }
        return result
    }
}
