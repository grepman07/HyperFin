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
            SDTelemetryEvent.self,
            SDSecurity.self,
            SDHolding.self,
            SDInvestmentTransaction.self,
            SDLiability.self,
        ])

        let configuration = ModelConfiguration(
            "HyperFin",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true
        )

        // Pre-create Application Support directory to avoid CoreData recovery noise
        if !inMemory {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            if !FileManager.default.fileExists(atPath: appSupport.path) {
                try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            }

            // Encrypt database files when the device is locked. Uses
            // `.completeUntilFirstUserAuthentication` (not `.complete`) so
            // background refresh tasks can still read the DB after the user
            // unlocks the device once post-boot. This matches what most
            // banking apps use — files are encrypted at rest in the locked
            // bootstate, but accessible for background sync after first unlock.
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: appSupport.path
            )
            #endif
        }

        HFLogger.data.info("Creating SwiftData container (inMemory: \(inMemory))")
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
