import Foundation
import SwiftData
import HFDomain
import HFShared

public final class SwiftDataAccountRepository: AccountRepository, @unchecked Sendable {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    public func fetchAll() async throws -> [Account] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDAccount>(sortBy: [SortDescriptor(\.institutionName)])
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    @MainActor
    public func fetch(id: UUID) async throws -> Account? {
        let context = container.mainContext
        let targetId = id
        let descriptor = FetchDescriptor<SDAccount>(predicate: #Predicate { $0.id == targetId })
        return try context.fetch(descriptor).first?.toDomain()
    }

    @MainActor
    public func save(_ account: Account) async throws {
        let context = container.mainContext
        let targetId = account.id
        let descriptor = FetchDescriptor<SDAccount>(predicate: #Predicate { $0.id == targetId })
        if let existing = try context.fetch(descriptor).first {
            existing.currentBalance = account.currentBalance
            existing.availableBalance = account.availableBalance
            existing.lastSynced = account.lastSynced
            existing.isActive = account.isActive
        } else {
            context.insert(SDAccount(from: account))
        }
        try context.save()
    }

    @MainActor
    public func delete(id: UUID) async throws {
        let context = container.mainContext
        let targetId = id
        let descriptor = FetchDescriptor<SDAccount>(predicate: #Predicate { $0.id == targetId })
        if let item = try context.fetch(descriptor).first {
            context.delete(item)
            try context.save()
        }
    }

    @MainActor
    public func totalBalance() async throws -> Decimal {
        let accounts = try await fetchAll()
        return accounts.filter { $0.isActive }.reduce(Decimal.zero) { $0 + $1.currentBalance }
    }
}
