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

    // Networking
    let apiClient: APIClient
    let authService: AuthService
    let plaidService: PlaidService

    // AI
    let modelManager: ModelManager
    let inferenceEngine: InferenceEngine
    let chatEngine: ChatEngine

    // Security
    let biometricAuth: BiometricAuthManager
    let keychain: KeychainManager

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

        // Networking
        self.apiClient = APIClient()
        self.authService = AuthService(apiClient: apiClient)
        self.plaidService = PlaidService(apiClient: apiClient)

        // AI Engine
        self.modelManager = ModelManager()
        self.inferenceEngine = InferenceEngine(modelManager: modelManager)
        self.chatEngine = ChatEngine(inferenceEngine: inferenceEngine, modelManager: modelManager)

        // Security
        self.biometricAuth = BiometricAuthManager()
        self.keychain = KeychainManager()

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
}
