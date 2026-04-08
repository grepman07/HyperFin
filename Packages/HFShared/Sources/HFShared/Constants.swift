import Foundation

public enum HFConstants {
    public enum API {
        #if DEBUG
        // Use Mac's local IP so physical devices can reach the dev server.
        // Change this to your Mac's current IP (run: ipconfig getifaddr en0).
        public static let baseURL = "http://192.168.7.21:3000"
        #else
        public static let baseURL = "https://api.hyperfin.app"
        #endif
        public static let apiVersion = "v1"
        public static let timeoutInterval: TimeInterval = 30
    }

    public enum Sync {
        public static let refreshIntervalHours = 4
        public static let maxTransactionsPerSync = 500
        public static let initialHistoryDays = 90
    }

    public enum AI {
        public static let modelName = "gemma-3-1b-it-4bit"
        public static let modelDirectory = "Models"
        public static let maxGenerationTokens = 512
        public static let temperature: Float = 0.7
        public static let minAvailableMemoryMB = 512
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
}
