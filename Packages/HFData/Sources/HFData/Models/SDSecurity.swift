import Foundation
import SwiftData
import HFDomain

@Model
public final class SDSecurity {
    @Attribute(.unique) public var securityId: String
    public var tickerSymbol: String?
    public var name: String?
    public var type: String?
    public var closePrice: Double?
    public var currencyCode: String
    public var updatedAt: Date

    public init(from domain: Security) {
        self.securityId = domain.securityId
        self.tickerSymbol = domain.tickerSymbol
        self.name = domain.name
        self.type = domain.type
        self.closePrice = domain.closePrice
        self.currencyCode = domain.currencyCode
        self.updatedAt = Date()
    }

    public func toDomain() -> Security {
        Security(
            securityId: securityId,
            tickerSymbol: tickerSymbol,
            name: name,
            type: type,
            closePrice: closePrice,
            currencyCode: currencyCode
        )
    }
}
