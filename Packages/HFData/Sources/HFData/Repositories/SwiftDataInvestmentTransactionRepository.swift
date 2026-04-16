import Foundation
import SwiftData
import HFDomain

public final class SwiftDataInvestmentTransactionRepository:
    InvestmentTransactionRepository, @unchecked Sendable {

    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    public func fetchAll() async throws -> [InvestmentTransaction] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDInvestmentTransaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    @MainActor
    public func fetch(from: Date, to: Date) async throws -> [InvestmentTransaction] {
        let context = container.mainContext
        let start = from
        let end = to
        let descriptor = FetchDescriptor<SDInvestmentTransaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }
}
