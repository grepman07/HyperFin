import Foundation
import HFShared
import os

#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
#endif

public enum ModelError: Error, Sendable {
    case modelNotFound
    case modelLoadFailed(String)
    case insufficientMemory
    case inferenceTimeout
    case modelNotLoaded
    case downloadFailed(String)
    case notSupported
}

public enum ModelStatus: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case loaded
    case error(String)
    case notSupported

    public static func == (lhs: ModelStatus, rhs: ModelStatus) -> Bool {
        switch (lhs, rhs) {
        case (.notDownloaded, .notDownloaded), (.downloaded, .downloaded),
             (.loading, .loading), (.loaded, .loaded), (.notSupported, .notSupported):
            return true
        case (.downloading(let a), .downloading(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Thread-safe progress tracker that can be updated from any isolation context.
private final class ProgressTracker: Sendable {
    private let _fraction: OSAllocatedUnfairLock<Double> = .init(initialState: 0)

    var fraction: Double {
        _fraction.withLock { $0 }
    }

    func update(_ value: Double) {
        _fraction.withLock { $0 = value }
    }
}

public actor ModelManager {
    private(set) public var status: ModelStatus = .notDownloaded
    private var isInferenceRunning = false

    #if canImport(MLXLLM)
    private var modelContainer: ModelContainer?
    #endif

    private let modelId: String

    public init(modelId: String = HFConstants.AI.modelHuggingFaceId) {
        self.modelId = modelId
    }

    public var currentStatus: ModelStatus { status }

    public var isLoaded: Bool {
        if case .loaded = status { return true }
        return false
    }

    public static var isMLXSupported: Bool {
        #if canImport(MLXLLM) && !targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    public func loadModel() async throws {
        guard ModelManager.isMLXSupported else {
            status = .notSupported
            HFLogger.ai.info("MLX not supported on this platform (simulator or missing Metal)")
            throw ModelError.notSupported
        }

        #if canImport(MLXLLM) && !targetEnvironment(simulator)
        status = .downloading(progress: 0)
        let currentModelId = self.modelId
        HFLogger.ai.info("Loading model: \(currentModelId)")

        // Reduce GPU cache to leave more memory for model weights
        Memory.cacheLimit = 256 * 1024 * 1024

        let configuration = ModelConfiguration(id: currentModelId)

        // Retry up to 3 times for download failures
        let maxRetries = 3
        var lastError: Error?

        for attempt in 1...maxRetries {
            do {
                HFLogger.ai.info("Download attempt \(attempt)/\(maxRetries) for \(currentModelId)")

                // Use a lock-based tracker so the progress callback doesn't need actor access
                let tracker = ProgressTracker()

                // Poll progress in a separate task since the callback can't await actor methods
                let pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        let frac = tracker.fraction
                        await self?.updateProgress(frac)
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }

                let container = try await LLMModelFactory.shared.loadContainer(
                    configuration: configuration
                ) { progress in
                    tracker.update(progress.fractionCompleted)
                }

                pollTask.cancel()

                self.modelContainer = container
                status = .loaded
                HFLogger.ai.info("Model loaded successfully: \(currentModelId)")
                return  // Success — exit the function
            } catch {
                lastError = error
                HFLogger.ai.error("Attempt \(attempt) failed: \(error.localizedDescription)")

                if attempt < maxRetries {
                    status = .downloading(progress: 0)
                    // Wait before retrying (2s, 4s)
                    try? await Task.sleep(for: .seconds(2 * attempt))
                }
            }
        }

        // All retries exhausted
        let msg = lastError?.localizedDescription ?? "Unknown download error"
        status = .error(msg)
        HFLogger.ai.error("Model download failed after \(maxRetries) attempts: \(msg)")
        throw ModelError.downloadFailed(msg)
        #else
        status = .notSupported
        throw ModelError.notSupported
        #endif
    }

    private func updateProgress(_ fraction: Double) {
        status = .downloading(progress: fraction)
    }

    public func evict() {
        #if canImport(MLXLLM)
        modelContainer = nil
        #endif
        status = .notDownloaded
        HFLogger.ai.info("Model evicted from memory")
    }

    #if canImport(MLXLLM) && !targetEnvironment(simulator)
    public func getContainer() -> ModelContainer? {
        modelContainer
    }
    #endif

    public func acquireInference() async throws {
        while isInferenceRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        isInferenceRunning = true
    }

    public func releaseInference() {
        isInferenceRunning = false
    }
}
