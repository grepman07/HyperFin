import Foundation
import SwiftData
import HFDomain
import HFShared
import HFSecurity
import HFData
import HFNetworking
import HFIntelligence

extension Notification.Name {
    /// Posted when the APIClient detects that the stored session tokens are
    /// no longer valid (refresh failed). RootView listens to this to bounce
    /// the user back to the login screen.
    static let hfAuthFailed = Notification.Name("com.hyperfin.authFailed")
}

/// Composition root — all dependencies are constructed here and injected via constructors.
@Observable
final class AppDependencies {
    let modelContainer: ModelContainer

    // Repositories
    let accountRepo: SwiftDataAccountRepository
    let transactionRepo: SwiftDataTransactionRepository
    let categoryRepo: SwiftDataCategoryRepository
    let telemetryRepo: SwiftDataTelemetryEventRepository

    // Wealth repositories (read-only; writes happen in PlaidLinkHandler)
    let holdingRepo: SwiftDataHoldingRepository
    let securityRepo: SwiftDataSecurityRepository
    let investmentTxnRepo: SwiftDataInvestmentTransactionRepository
    let liabilityRepo: SwiftDataLiabilityRepository

    // Networking
    let apiClient: APIClient
    let authService: AuthService
    let plaidService: PlaidService
    let telemetryService: TelemetryService

    // AI
    let modelManager: ModelManager
    let inferenceEngine: InferenceEngine
    let cloudInferenceEngine: CloudInferenceEngine
    let toolRegistry: ToolRegistry
    let chatEngine: ChatEngine
    /// Phase 1 semantic router — uses Apple NLEmbedding as the cold-start
    /// embedding backend. Swappable for a trained MLX model later without
    /// API changes. See docs/CHAT_ARCHITECTURE.md.
    let semanticRouter: SemanticRouter

    // Security
    let biometricAuth: BiometricAuthManager
    let keychain: KeychainManager
    let installIdProvider: InstallIdProvider

    // Telemetry
    let telemetryLogger: TelemetryLogger

    init() {
        // SwiftData container with all model types
        do {
            self.modelContainer = try SwiftDataContainer.create()
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }

        // Repositories
        self.accountRepo = SwiftDataAccountRepository(container: modelContainer)
        self.transactionRepo = SwiftDataTransactionRepository(container: modelContainer)
        self.categoryRepo = SwiftDataCategoryRepository(container: modelContainer)
        self.telemetryRepo = SwiftDataTelemetryEventRepository(container: modelContainer)
        self.holdingRepo = SwiftDataHoldingRepository(container: modelContainer)
        self.securityRepo = SwiftDataSecurityRepository(container: modelContainer)
        self.investmentTxnRepo = SwiftDataInvestmentTransactionRepository(container: modelContainer)
        self.liabilityRepo = SwiftDataLiabilityRepository(container: modelContainer)

        // Networking
        self.apiClient = APIClient()
        self.authService = AuthService(apiClient: apiClient)
        self.plaidService = PlaidService(apiClient: apiClient)
        self.telemetryService = TelemetryService(apiClient: apiClient)

        // Security — constructed before ChatEngine so installId is available
        // for the CloudInferenceEngine.
        self.biometricAuth = BiometricAuthManager()
        self.keychain = KeychainManager()
        self.installIdProvider = InstallIdProvider(keychain: keychain)

        // Persist refreshed tokens to Keychain so they survive app restarts.
        let kc = keychain
        let ac = apiClient
        Task {
            await ac.setTokenRefreshCallback { access, refresh in
                try? kc.saveString(key: "accessToken", value: access)
                try? kc.saveString(key: "refreshToken", value: refresh)
            }
            // When refresh fails (e.g. refresh token expired, or server JWT
            // secret rotated), clear stale Keychain entries and post a
            // notification so RootView can bounce to the login screen.
            await ac.setAuthFailureCallback {
                try? kc.delete(key: "accessToken")
                try? kc.delete(key: "refreshToken")
                await MainActor.run {
                    NotificationCenter.default.post(name: .hfAuthFailed, object: nil)
                }
            }
        }

        let container = modelContainer
        let installId = installIdProvider.currentInstallId()
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

        // AI Engine — local model (always on) + cloud engine (gated by
        // UserProfile.cloudChatOptIn at the ChatEngine routing layer).
        self.modelManager = ModelManager()
        self.inferenceEngine = InferenceEngine(modelManager: modelManager)
        self.cloudInferenceEngine = CloudInferenceEngine(
            apiClient: apiClient,
            installId: installId
        )
        // ToolRegistry owns the catalog of tools the planner can call. It
        // needs the repo graph, which SwiftData produces synchronously — so
        // registry construction happens inline and repos are wired below.
        self.toolRegistry = ToolRegistry()

        // Semantic router — Phase 1 uses Apple's NLEmbedding (no download,
        // OS-resident). Prewarming (embedding all seed exemplars) happens
        // in a detached Task below so startup isn't blocked.
        let embedProvider = NLEmbeddingProvider()
        self.semanticRouter = SemanticRouter(provider: embedProvider)

        self.chatEngine = ChatEngine(
            inferenceEngine: inferenceEngine,
            modelManager: modelManager,
            registry: toolRegistry,
            cloudEngine: cloudInferenceEngine,
            semanticRouter: semanticRouter
        )

        self.telemetryLogger = TelemetryLogger(
            repo: telemetryRepo,
            uploader: telemetryService,
            installId: installId,
            appVersion: appVersion,
            modelVersion: HFConstants.AI.modelName,
            isOptedInProvider: {
                await Self.fetchOptIn(container: container)
            },
            userNameProvider: {
                await Self.fetchDisplayName(container: container)
            }
        )

        // Wire the tool registry with the full repo graph. The registry
        // is what the ToolPlanner will drive — ChatEngine doesn't hold
        // repos itself anymore, it delegates to the registry per-call.
        let registry = toolRegistry
        let aRepo = accountRepo
        let tRepo = transactionRepo
        let cRepo = categoryRepo
        let budgetRepo = SwiftDataBudgetRepository(container: modelContainer)
        let hRepo = holdingRepo
        let sRepo = securityRepo
        let iRepo = investmentTxnRepo
        let lRepo = liabilityRepo
        Task { @MainActor in
            let repos = ToolRepos(
                transactions: tRepo,
                categories: cRepo,
                accounts: aRepo,
                budgets: budgetRepo,
                holdings: hRepo,
                securities: sRepo,
                investmentTransactions: iRepo,
                liabilities: lRepo
            )
            await registry.setRepos(repos)
        }

        // Prewarm the semantic router. Embedding all seed exemplars takes
        // a few hundred milliseconds with NLEmbedding; doing it eagerly in
        // the background means the first real query lands on a hot router.
        let router = semanticRouter
        Task.detached {
            await router.prewarm()
        }

        // Seed sample data for testing on first launch
        let mc = modelContainer
        Task { @MainActor in
            let seeder = SampleDataSeeder(container: mc)
            await seeder.seedIfNeeded()
        }

        // Kick off the on-device model download at launch. Uses Task.detached
        // so the download is NOT tied to any SwiftUI view's `.task` lifecycle
        // — navigating between tabs mid-download would otherwise cancel the
        // parent task and URLSession would surface every retry as
        // URLError.cancelled. See ChatView for the view-side companion which
        // now only reads status.`
        let mm = modelManager
        Task.detached {
            let status = await mm.currentStatus
            if case .loaded = status { return }
            do {
                try await mm.loadModel()
            } catch {
                // loadModel already logs failures; swallow here so a failed
                // download never takes the app down. The user can retry
                // manually from Settings → On-Device AI.
                HFLogger.ai.error("Background model load failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - Telemetry profile helpers

    @MainActor
    private static func fetchOptIn(container: ModelContainer) -> Bool {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDUserProfile>()
        return (try? context.fetch(descriptor).first?.telemetryOptIn) ?? false
    }

    @MainActor
    private static func fetchDisplayName(container: ModelContainer) -> String? {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDUserProfile>()
        return try? context.fetch(descriptor).first?.displayName
    }
}
