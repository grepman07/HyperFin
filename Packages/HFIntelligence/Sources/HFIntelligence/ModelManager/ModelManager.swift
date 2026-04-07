import Foundation
import HFShared

public enum ModelError: Error, Sendable {
    case modelNotFound
    case modelLoadFailed(String)
    case insufficientMemory
    case inferenceTimeout
    case modelNotLoaded
    case downloadFailed(String)
}

public enum ModelStatus: Sendable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case loading
    case loaded
    case error(String)
}

public actor ModelManager {
    private var status: ModelStatus = .notDownloaded
    private var isInferenceRunning = false

    private let modelDirectory: URL
    private let modelName: String

    public init(
        modelName: String = HFConstants.AI.modelName,
        modelDirectory: URL? = nil
    ) {
        self.modelName = modelName
        if let dir = modelDirectory {
            self.modelDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.modelDirectory = appSupport.appendingPathComponent(HFConstants.AI.modelDirectory)
        }
    }

    public var currentStatus: ModelStatus { status }

    public var modelPath: URL {
        modelDirectory.appendingPathComponent(modelName)
    }

    public var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    public func ensureModelDirectory() throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
    }

    public func checkMemoryAvailability() -> Bool {
        #if os(iOS)
        let available = os_proc_available_memory()
        let minRequired = UInt64(HFConstants.AI.minAvailableMemoryMB) * 1024 * 1024
        let isAvailable = available > minRequired
        HFLogger.ai.info("Available memory: \(available / 1024 / 1024)MB, required: \(HFConstants.AI.minAvailableMemoryMB)MB, ok: \(isAvailable)")
        return isAvailable
        #else
        return true
        #endif
    }

    public func loadModel() async throws {
        guard isModelDownloaded else {
            throw ModelError.modelNotFound
        }

        guard checkMemoryAvailability() else {
            throw ModelError.insufficientMemory
        }

        status = .loading
        HFLogger.ai.info("Loading model from \(self.modelPath.path)")

        // MLX-Swift or Core ML model loading will be implemented here
        // during the AI Development phase (Months 3-5).
        //
        // MLX-Swift approach:
        //   let model = try await MLXModelLoader.load(from: modelPath)
        //   self.loadedModel = model
        //
        // Core ML approach:
        //   let config = MLModelConfiguration()
        //   config.computeUnits = .cpuAndNeuralEngine
        //   let model = try await MLModel.load(contentsOf: modelPath, configuration: config)

        status = .loaded
        HFLogger.ai.info("Model loaded successfully")
    }

    public func evict() {
        status = .downloaded
        HFLogger.ai.info("Model evicted from memory")
    }

    public func setDownloading(progress: Double) {
        status = .downloading(progress: progress)
    }

    public func setDownloaded() {
        status = .downloaded
    }

    public func setError(_ message: String) {
        status = .error(message)
    }

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
