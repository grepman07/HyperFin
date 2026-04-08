import Foundation
import SwiftData
import HFDomain

@Model
public final class SDMerchantMapping {
    @Attribute(.unique) public var id: UUID
    public var merchantName: String
    public var categoryId: UUID
    public var confidence: Float
    public var sourceRaw: String
    public var lastUpdated: Date

    public init(from domain: MerchantMapping) {
        self.id = domain.id
        self.merchantName = domain.merchantName
        self.categoryId = domain.categoryId
        self.confidence = domain.confidence
        self.sourceRaw = domain.source.rawValue
        self.lastUpdated = domain.lastUpdated
    }

    public func toDomain() -> MerchantMapping {
        MerchantMapping(
            id: id,
            merchantName: merchantName,
            categoryId: categoryId,
            confidence: confidence,
            source: MappingSource(rawValue: sourceRaw) ?? .rule,
            lastUpdated: lastUpdated
        )
    }
}
