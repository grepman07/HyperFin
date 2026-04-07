import Foundation
import SwiftData
import HFDomain
import HFShared

public final class SwiftDataBudgetRepository: BudgetRepository, @unchecked Sendable {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    public func fetch(month: Date) async throws -> Budget? {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDBudget>()
        let budgets = try context.fetch(descriptor)
        return budgets.first { Calendar.current.isDate($0.month, equalTo: month, toGranularity: .month) }?.toDomain()
    }

    @MainActor
    public func fetchAll() async throws -> [Budget] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDBudget>(sortBy: [SortDescriptor(\.month, order: .reverse)])
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    @MainActor
    public func save(_ budget: Budget) async throws {
        let context = container.mainContext
        let sd = SDBudget(from: budget)
        context.insert(sd)
        for line in budget.lines {
            let sdLine = SDBudgetLine(from: line)
            sdLine.budget = sd
            context.insert(sdLine)
        }
        try context.save()
    }

    @MainActor
    public func delete(id: UUID) async throws {
        let context = container.mainContext
        let targetId = id
        let descriptor = FetchDescriptor<SDBudget>(predicate: #Predicate { $0.id == targetId })
        if let item = try context.fetch(descriptor).first {
            context.delete(item)
            try context.save()
        }
    }
}
