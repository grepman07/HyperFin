import Foundation
import SwiftData
import HFDomain
import HFShared
import HFSecurity
import HFData
import HFNetworking
import HFIntelligence

/// Composition root — all dependencies are constructed here and injected via constructors.
@Observable
final class AppDependencies {
    let modelContainer: ModelContainer

    // Repositories
    let accountRepo: SwiftDataAccountRepository
    let transactionRepo: SwiftDataTransactionRepository
    let categoryRepo: SwiftDataCategoryRepository
    let telemetryRepo: SwiftDataTelemetryEventRepository

    // Networking
    let apiClient: APIClient
    let authService: AuthService
    let plaidService: PlaidService
    let telemetryService: TelemetryService

    // AI
    let modelManager: ModelManager
    let inferenceEngine: InferenceEngine
    let chatEngine: ChatEngine

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

        // Networking
        self.apiClient = APIClient()
        self.authService = AuthService(apiClient: apiClient)
        self.plaidService = PlaidService(apiClient: apiClient)
        self.telemetryService = TelemetryService(apiClient: apiClient)

        // AI Engine
        self.modelManager = ModelManager()
        self.inferenceEngine = InferenceEngine(modelManager: modelManager)
        self.chatEngine = ChatEngine(inferenceEngine: inferenceEngine, modelManager: modelManager)

        // Security
        self.biometricAuth = BiometricAuthManager()
        self.keychain = KeychainManager()
        self.installIdProvider = InstallIdProvider(keychain: keychain)

        // Telemetry — providers close over modelContainer so opt-in and user
        // name are always fresh from SwiftData, not a stale snapshot.
        let container = modelContainer
        let installId = installIdProvider.currentInstallId()
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

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

        // Wire ChatEngine with repositories
        let engine = chatEngine
        let aRepo = accountRepo
        let tRepo = transactionRepo
        let cRepo = categoryRepo
        let budgetRepo = SwiftDataBudgetRepository(container: modelContainer)
        Task { @MainActor in
            await engine.setRepositories(
                transactions: tRepo,
                categories: cRepo,
                accounts: aRepo,
                budgets: budgetRepo
            )
        }

        // Seed sample data for testing on first launch
        let mc = modelContainer
        Task { @MainActor in
            let seeder = SampleDataSeeder(container: mc)
            await seeder.seedIfNeeded()
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
