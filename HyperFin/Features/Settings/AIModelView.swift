import SwiftUI
import HFIntelligence
import HFShared

struct AIModelView: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var modelStatus: ModelStatus = .notDownloaded
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section("On-Device AI") {
                HStack {
                    Label("Model", systemImage: "brain")
                    Spacer()
                    Text(HFConstants.AI.modelDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Runtime", systemImage: "cpu")
                    Spacer()
                    Text("MLX-Swift")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label("Status", systemImage: statusIcon)
                    Spacer()
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }

            Section {
                if case .loaded = modelStatus {
                    Label("Model loaded and ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if case .downloading(let progress) = modelStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Downloading model...")
                            .font(.subheadline)
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))% complete")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        loadModel()
                    } label: {
                        HStack {
                            Label("Download & Load Model", systemImage: "arrow.down.circle")
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text(HFConstants.AI.modelDownloadSize)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(isLoading || !ModelManager.isMLXSupported)

                    if !ModelManager.isMLXSupported {
                        Text("MLX requires a physical iPhone with Apple Silicon. The AI model cannot run in the simulator.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Privacy") {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("100% On-Device Processing")
                            .font(.subheadline.bold())
                        Text("All AI inference runs locally. Your financial data never leaves your iPhone for AI processing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("On-Device AI")
        .task {
            modelStatus = await dependencies.modelManager.currentStatus
        }
    }

    private func loadModel() {
        isLoading = true
        errorMessage = nil

        Task {
            // Poll model status during download so UI updates
            let pollTask = Task {
                while !Task.isCancelled {
                    let s = await dependencies.modelManager.currentStatus
                    await MainActor.run { modelStatus = s }
                    try await Task.sleep(for: .milliseconds(200))
                }
            }

            do {
                try await dependencies.modelManager.loadModel()
                modelStatus = await dependencies.modelManager.currentStatus
            } catch ModelError.notSupported {
                errorMessage = "MLX is not supported on this device. Use a physical iPhone with A17 Pro or later."
                modelStatus = .notSupported
            } catch {
                errorMessage = error.localizedDescription
                modelStatus = .error(error.localizedDescription)
            }
            pollTask.cancel()
            isLoading = false
        }
    }

    private var statusIcon: String {
        switch modelStatus {
        case .loaded: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case .loading: "hourglass"
        case .error: "exclamationmark.triangle.fill"
        case .notSupported: "xmark.circle"
        default: "circle.dashed"
        }
    }

    private var statusText: String {
        switch modelStatus {
        case .loaded: "Loaded"
        case .downloading(let p): "Downloading \(Int(p * 100))%"
        case .loading: "Loading..."
        case .error: "Error"
        case .notSupported: "Not Supported"
        case .notDownloaded: "Not Downloaded"
        case .downloaded: "Downloaded"
        }
    }

    private var statusColor: Color {
        switch modelStatus {
        case .loaded: .green
        case .downloading, .loading: .blue
        case .error, .notSupported: .red
        default: .secondary
        }
    }
}
