import Foundation

public enum MappingSource: String, Codable, Sendable {
    case userCorrection
    case aiInference
    case rule
}

public struct MerchantMapping: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var merchantName: String
    public var categoryId: UUID
    public var confidence: Float
    public var source: MappingSource
    public var lastUpdated: Date

    public init(
        id: UUID = UUID(),
        merchantName: String,
        categoryId: UUID,
        confidence: Float,
        source: MappingSource,
        lastUpdated: Date = Date()
    ) {
        self.id = id
        self.merchantName = merchantName
        self.categoryId = categoryId
        self.confidence = confidence
        self.source = source
        self.lastUpdated = lastUpdated
    }
}
