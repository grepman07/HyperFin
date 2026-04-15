import Foundation

public enum HFConstants {
    public enum API {
        /// In Debug builds, defaults to localhost for local sandbox testing.
        /// Override via the `HYPERFIN_API_URL` environment variable in the Xcode
        /// scheme to point at a different server (e.g. the DO production URL).
        /// Release builds always use the production URL.
        public static let baseURL: String = {
            #if DEBUG
            if let override = ProcessInfo.processInfo.environment["HYPERFIN_API_URL"],
               !override.isEmpty {
                return override
            }
            return "https://hyperfin-server-dzlsx.ondigitalocean.app"
            #else
            return "https://hyperfin-server-dzlsx.ondigitalocean.app"
            #endif
        }()
        public static let apiVersion = "v1"
        public static let timeoutInterval: TimeInterval = 30
        /// Endpoint path (under /<apiVersion>/) for the server-side cloud chat
        /// proxy that streams Claude Haiku responses back to the client.
        public static let cloudChatStreamPath = "chat/stream"
        /// Streaming inference can take substantially longer than a regular
        /// request, so we give it its own timeout.
        public static let cloudChatTimeoutInterval: TimeInterval = 60
    }

    public enum Sync {
        public static let refreshIntervalHours = 4
        public static let maxTransactionsPerSync = 500
        public static let initialHistoryDays = 90
    }

    public enum AI {
        public static let modelName = "Qwen2.5-3B-Instruct-4bit"
        public static let modelHuggingFaceId = "mlx-community/Qwen2.5-3B-Instruct-4bit"
        /// Short label for compact rows ("Qwen 2.5 3B").
        public static let modelShortDisplayName = "Qwen 2.5 3B"
        /// Full label with quantization ("Qwen 2.5 3B (4-bit)").
        public static let modelDisplayName = "Qwen 2.5 3B (4-bit)"
        /// Approximate on-disk download size for UI display.
        public static let modelDownloadSize = "~1.7 GB"
        public static let modelDirectory = "Models"
        public static let maxGenerationTokens = 512
        public static let temperature: Float = 0.6
        public static let minAvailableMemoryMB = 1024
        public static let receiptParsingMaxTokens = 256
        public static let receiptParsingTemperature: Float = 0.1
        public static let classificationMaxTokens = 100
        public static let classificationTemperature: Float = 0.1
        /// MLX GPU cache limit in bytes. Bumped from 256 MB → 512 MB for the
        /// larger 3B model (weights are ~1.74 GB quantized).
        public static let mlxCacheLimitBytes = 512 * 1024 * 1024
    }

    public enum Budget {
        public static let warningThreshold: Decimal = 0.80
        public static let exceededThreshold: Decimal = 1.0
        public static let minTransactionDaysForSuggestion = 30
    }

    public enum Security {
        public static let sessionTimeoutMinutes = 15
        public static let keychainService = "com.hyperfin.keychain"
        public static let secureEnclaveTag = "com.hyperfin.enclave.key"
    }

    public enum App {
        public static let bundleId = "com.hyperfin.app"
        public static let appGroup = "group.com.hyperfin.app"
        public static let minimumIOSVersion = "17.0"
    }

    public enum Chat {
        /// Chat messages older than this are auto-purged from SwiftData on
        /// app launch and excluded from history restoration. The rolling
        /// window keeps the conversation feeling continuous without letting
        /// the on-device store grow unbounded.
        public static let historyRetentionDays = 30
    }

    public enum Telemetry {
        /// Max events per upload batch.
        public static let batchSize = 50
        /// Minimum seconds between flush attempts (rate limiter).
        public static let minFlushGapSeconds: TimeInterval = 30
        /// After this many failed attempts, the event is dropped from the local queue.
        public static let maxAttempts = 5
        /// A foreground resume counts as "idle" and triggers a flush only after this idle gap.
        public static let foregroundIdleFlushSeconds: TimeInterval = 300
    }
}
