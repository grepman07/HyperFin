import Foundation
import SwiftData

/// Composition root — all dependencies are constructed here and injected via constructors.
/// No DI framework needed.
@Observable
final class AppDependencies {
    let modelContainer: ModelContainer

    // Repositories — would be initialized from HFData package
    // let accountRepo: AccountRepository
    // let transactionRepo: TransactionRepository
    // let categoryRepo: CategoryRepository
    // let budgetRepo: BudgetRepository
    // let merchantMappingRepo: MerchantMappingRepository
    // let chatMessageRepo: ChatMessageRepository
    // let alertConfigRepo: AlertConfigRepository
    // let userProfileRepo: UserProfileRepository

    // Services — would be initialized from HFNetworking + HFIntelligence
    // let apiClient: APIClient
    // let authService: AuthService
    // let plaidService: PlaidService
    // let modelManager: ModelManager
    // let inferenceEngine: InferenceEngine
    // let chatEngine: ChatEngine
    // let categorizer: TransactionCategorizerImpl

    // Security
    // let biometricAuth: BiometricAuthManager
    // let keychain: KeychainManager

    init() {
        // Initialize SwiftData container
        do {
            self.modelContainer = try ModelContainer(for: Schema([]))
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        // Full dependency wiring will be enabled once packages are
        // linked to the Xcode project target. Example:
        //
        // let container = try SwiftDataContainer.create()
        // self.modelContainer = container
        //
        // self.accountRepo = SwiftDataAccountRepository(container: container)
        // self.transactionRepo = SwiftDataTransactionRepository(container: container)
        // self.categoryRepo = SwiftDataCategoryRepository(container: container)
        //
        // self.apiClient = APIClient()
        // self.authService = AuthService(apiClient: apiClient)
        // self.plaidService = PlaidService(apiClient: apiClient)
        //
        // self.modelManager = ModelManager()
        // self.inferenceEngine = InferenceEngine(modelManager: modelManager)
        // self.chatEngine = ChatEngine(inferenceEngine: inferenceEngine, modelManager: modelManager)
        // self.chatEngine.setRepositories(...)
        //
        // self.biometricAuth = BiometricAuthManager()
        // self.keychain = KeychainManager()
    }
}
