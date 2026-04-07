import Foundation
import SwiftData
import HFShared

public enum SwiftDataContainer {
    public static func create(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            SDAccount.self,
            SDTransaction.self,
            SDCategory.self,
            SDBudget.self,
            SDBudgetLine.self,
            SDMerchantMapping.self,
            SDChatMessage.self,
            SDAlertConfig.self,
            SDUserProfile.self,
        ])

        let configuration = ModelConfiguration(
            "HyperFin",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true
        )

        HFLogger.data.info("Creating SwiftData container (inMemory: \(inMemory))")
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
