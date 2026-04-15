import Foundation
import SwiftData
import HFDomain

@Model
public final class SDHolding {
    @Attribute(.unique) public var id: UUID
    public var accountId: String
    public var securityId: String
    public var quantity: Double
    public var institutionPrice: Double?
    public var institutionValue: Double?
    public var costBasis: Double?
    public var currencyCode: String
    public var updatedAt: Date

    public init(from domain: Holding) {
        self.id = domain.id
        self.accountId = domain.accountId
        self.securityId = domain.securityId
        self.quantity = domain.quantity
        self.institutionPrice = domain.institutionPrice
        self.institutionValue = domain.institutionValue
        self.costBasis = domain.costBasis
        self.currencyCode = domain.currencyCode
        self.updatedAt = Date()
    }

    public func toDomain() -> Holding {
        Holding(
            id: id,
            accountId: accountId,
            securityId: securityId,
            quantity: quantity,
            institutionPrice: institutionPrice,
            institutionValue: institutionValue,
            costBasis: costBasis,
            currencyCode: currencyCode
        )
    }
}
