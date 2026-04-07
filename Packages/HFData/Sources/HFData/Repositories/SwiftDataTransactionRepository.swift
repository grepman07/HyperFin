import Foundation
import SwiftData
import HFDomain
import HFShared

public final class SwiftDataTransactionRepository: TransactionRepository, @unchecked Sendable {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    public func fetch(accountId: UUID?, categoryId: UUID?, from: Date?, to: Date?, limit: Int?) async throws -> [Transaction] {
        let context = container.mainContext
        var descriptor = FetchDescriptor<SDTransaction>(sortBy: [SortDescriptor(\.date, order: .reverse)])

        if let limit { descriptor.fetchLimit = limit }

        let results = try context.fetch(descriptor)

        return results
            .filter { txn in
                if let accountId, txn.accountId != accountId { return false }
                if let categoryId, txn.categoryId != categoryId { return false }
                if let from, txn.date < from { return false }
                if let to, txn.date > to { return false }
                return true
            }
            .map { $0.toDomain() }
    }

    @MainActor
    public func fetch(id: UUID) async throws -> Transaction? {
        let context = container.mainContext
        let targetId = id
        let descriptor = FetchDescriptor<SDTransaction>(predicate: #Predicate { $0.id == targetId })
        return try context.fetch(descriptor).first?.toDomain()
    }

    @MainActor
    public func save(_ transactions: [Transaction]) async throws {
        let context = container.mainContext
        for txn in transactions {
            let sd = SDTransaction(from: txn)
            context.insert(sd)
        }
        try context.save()
        HFLogger.data.info("Saved \(transactions.count) transactions")
    }

    @MainActor
    public func update(_ transaction: Transaction) async throws {
        let context = container.mainContext
        let targetId = transaction.id
        let descriptor = FetchDescriptor<SDTransaction>(predicate: #Predicate { $0.id == targetId })
        if let existing = try context.fetch(descriptor).first {
            existing.amount = transaction.amount
            existing.merchantName = transaction.merchantName
            existing.categoryId = transaction.categoryId
            existing.isUserCategorized = transaction.isUserCategorized
            existing.notes = transaction.notes
            try context.save()
        }
    }

    @MainActor
    public func delete(id: UUID) async throws {
        let context = container.mainContext
        let targetId = id
        let descriptor = FetchDescriptor<SDTransaction>(predicate: #Predicate { $0.id == targetId })
        if let item = try context.fetch(descriptor).first {
            context.delete(item)
            try context.save()
        }
    }

    @MainActor
    public func searchByMerchant(_ name: String) async throws -> [Transaction] {
        let context = container.mainContext
        let lowered = name.lowercased()
        let descriptor = FetchDescriptor<SDTransaction>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        return try context.fetch(descriptor)
            .filter { ($0.merchantName ?? "").lowercased().contains(lowered) }
            .map { $0.toDomain() }
    }

    @MainActor
    public func spendingTotal(categoryId: UUID?, from: Date, to: Date) async throws -> Decimal {
        let transactions = try await fetch(accountId: nil, categoryId: categoryId, from: from, to: to, limit: nil)
        return transactions.filter { $0.isExpense }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    @MainActor
    public func transactionCount(from: Date, to: Date) async throws -> Int {
        let transactions = try await fetch(accountId: nil, categoryId: nil, from: from, to: to, limit: nil)
        return transactions.count
    }
}
