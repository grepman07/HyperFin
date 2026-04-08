import Foundation
import HFShared

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

public actor ModelManager {
    private(set) public var status: ModelStatus = .notDownloaded
    private var isInferenceRunning = false

    #if canImport(MLXLLM)
    private var modelContainer: ModelContainer?
    #endif

    private let modelId: String

    public init(modelId: String = "mlx-community/gemma-3-1b-it-4bit") {
        // Using Gemma 3 1B for broader device compatibility during development.
        // Upgrade to gemma-4-e4b-it-4bit for production (requires more RAM).
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

        do {
            // Set GPU cache limit for memory management
            MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)

            let configuration = ModelConfiguration(id: currentModelId)

            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { [weak self] progress in
                Task { [weak self] in
                    await self?.updateProgress(progress.fractionCompleted)
                }
            }

            self.modelContainer = container
            status = .loaded
            HFLogger.ai.info("Model loaded successfully: \(currentModelId)")
        } catch {
            let msg = error.localizedDescription
            status = .error(msg)
            HFLogger.ai.error("Model load failed: \(msg)")
            throw ModelError.modelLoadFailed(msg)
        }
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
