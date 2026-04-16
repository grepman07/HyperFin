import Foundation
import SwiftData
import HFDomain

public final class SwiftDataSecurityRepository: SecurityRepository, @unchecked Sendable {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    public func fetchAll() async throws -> [Security] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDSecurity>(sortBy: [SortDescriptor(\.tickerSymbol)])
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    @MainActor
    public func fetch(securityId: String) async throws -> Security? {
        let context = container.mainContext
        let target = securityId
        var descriptor = FetchDescriptor<SDSecurity>(
            predicate: #Predicate { $0.securityId == target }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.toDomain()
    }
}
