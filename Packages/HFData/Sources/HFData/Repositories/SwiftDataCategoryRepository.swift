import Foundation
import SwiftData
import HFDomain
import HFShared

public final class SwiftDataCategoryRepository: CategoryRepository, @unchecked Sendable {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    public func fetchAll() async throws -> [SpendingCategory] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDCategory>(sortBy: [SortDescriptor(\.name)])
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    @MainActor
    public func fetch(id: UUID) async throws -> SpendingCategory? {
        let context = container.mainContext
        let targetId = id
        let descriptor = FetchDescriptor<SDCategory>(predicate: #Predicate { $0.id == targetId })
        return try context.fetch(descriptor).first?.toDomain()
    }

    @MainActor
    public func save(_ category: SpendingCategory) async throws {
        let context = container.mainContext
        context.insert(SDCategory(from: category))
        try context.save()
    }

    @MainActor
    public func seedSystemCategories() async throws {
        let existing = try await fetchAll()
        guard existing.isEmpty else { return }

        let context = container.mainContext
        for category in SpendingCategory.systemCategories {
            context.insert(SDCategory(from: category))
        }
        try context.save()
        HFLogger.data.info("Seeded \(SpendingCategory.systemCategories.count) system categories")
    }
}
