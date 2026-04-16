import Foundation

public protocol AccountRepository: Sendable {
    func fetchAll() async throws -> [Account]
    func fetch(id: UUID) async throws -> Account?
    func save(_ account: Account) async throws
    func delete(id: UUID) async throws
    func totalBalance() async throws -> Decimal
}

public protocol TransactionRepository: Sendable {
    func fetch(accountId: UUID?, categoryId: UUID?, from: Date?, to: Date?, limit: Int?) async throws -> [Transaction]
    func fetch(id: UUID) async throws -> Transaction?
    func save(_ transactions: [Transaction]) async throws
    func update(_ transaction: Transaction) async throws
    func delete(id: UUID) async throws
    func searchByMerchant(_ name: String) async throws -> [Transaction]
    func spendingTotal(categoryId: UUID?, from: Date, to: Date) async throws -> Decimal
    func transactionCount(from: Date, to: Date) async throws -> Int
}

public protocol CategoryRepository: Sendable {
    func fetchAll() async throws -> [SpendingCategory]
    func fetch(id: UUID) async throws -> SpendingCategory?
    func save(_ category: SpendingCategory) async throws
    func seedSystemCategories() async throws
}

public protocol BudgetRepository: Sendable {
    func fetch(month: Date) async throws -> Budget?
    func fetchAll() async throws -> [Budget]
    func save(_ budget: Budget) async throws
    func delete(id: UUID) async throws
}

public protocol MerchantMappingRepository: Sendable {
    func fetch(merchantName: String) async throws -> MerchantMapping?
    func save(_ mapping: MerchantMapping) async throws
    func fetchAll() async throws -> [MerchantMapping]
}

public protocol ChatMessageRepository: Sendable {
    func fetch(sessionId: UUID, limit: Int?) async throws -> [ChatMessage]
    func save(_ message: ChatMessage) async throws
    func deleteSession(id: UUID) async throws
}

public protocol AlertConfigRepository: Sendable {
    func fetchAll() async throws -> [AlertConfig]
    func save(_ config: AlertConfig) async throws
    func fetchEnabled() async throws -> [AlertConfig]
}

public protocol UserProfileRepository: Sendable {
    func fetch() async throws -> UserProfile?
    func save(_ profile: UserProfile) async throws
}

// ----------------------------------------------------------------------------
// Wealth read-only repositories
//
// The wealth side of the app (holdings, investment activity, liabilities) is
// written wholesale by PlaidLinkHandler / sync jobs. Chat only ever reads,
// so these protocols expose fetch methods only — no save/delete — and map
// the opaque Plaid IDs to domain models for the tool layer to reason about.
// ----------------------------------------------------------------------------

public protocol HoldingRepository: Sendable {
    func fetchAll() async throws -> [Holding]
    /// Sum of `institutionValue` across all holdings (in account currency,
    /// treated as USD for the aggregate). Missing values are ignored.
    func totalValue() async throws -> Decimal
}

public protocol SecurityRepository: Sendable {
    func fetchAll() async throws -> [Security]
    func fetch(securityId: String) async throws -> Security?
}

public protocol InvestmentTransactionRepository: Sendable {
    func fetchAll() async throws -> [InvestmentTransaction]
    /// Filter by date window. Start is inclusive, end is exclusive.
    func fetch(from: Date, to: Date) async throws -> [InvestmentTransaction]
}

public protocol LiabilityRepository: Sendable {
    /// Returns every persisted liability, decoded into the matching domain
    /// enum case. Rows whose payload fails to decode are silently dropped.
    func fetchAll() async throws -> [Liability]
}
