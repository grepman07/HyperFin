import Foundation
import SwiftData
import HFDomain

public final class SwiftDataLiabilityRepository: LiabilityRepository, @unchecked Sendable {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    public func fetchAll() async throws -> [Liability] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<SDLiability>(sortBy: [SortDescriptor(\.kind)])
        // `toLiability()` decodes the opaque JSON payload per-kind. Rows that
        // fail to decode (shouldn't happen, but defend against schema drift)
        // are dropped rather than propagating a throw — the rest of the
        // liability list is still useful.
        return try context.fetch(descriptor).compactMap { $0.toLiability() }
    }
}
