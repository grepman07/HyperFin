import Foundation
import SwiftData
import HFDomain

public final class SwiftDataHoldingRepository: HoldingRepository, @unchecked Sendable {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    public func fetchAll() async throws -> [Holding] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDHolding>(sortBy: [SortDescriptor(\.accountId)])
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    @MainActor
    public func totalValue() async throws -> Decimal {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDHolding>()
        let rows = try context.fetch(descriptor)
        // institutionValue is Double; convert at the aggregation boundary so
        // downstream math (net worth, etc.) stays in Decimal like everything
        // else in the finance domain.
        let total = rows.reduce(0.0) { $0 + ($1.institutionValue ?? 0) }
        return Decimal(total)
    }
}
