import Foundation
import SwiftData
import HFDomain

@Model
public final class SDInvestmentTransaction {
    @Attribute(.unique) public var investmentTransactionId: String
    public var accountId: String
    public var securityId: String?
    public var date: Date
    public var name: String?
    public var type: String?
    public var subtype: String?
    public var quantity: Double?
    public var price: Double?
    public var fees: Double?
    public var amount: Double?
    public var currencyCode: String

    public init(from domain: InvestmentTransaction) {
        self.investmentTransactionId = domain.investmentTransactionId
        self.accountId = domain.accountId
        self.securityId = domain.securityId
        self.date = domain.date
        self.name = domain.name
        self.type = domain.type
        self.subtype = domain.subtype
        self.quantity = domain.quantity
        self.price = domain.price
        self.fees = domain.fees
        self.amount = domain.amount
        self.currencyCode = domain.currencyCode
    }

    public func toDomain() -> InvestmentTransaction {
        InvestmentTransaction(
            investmentTransactionId: investmentTransactionId,
            accountId: accountId,
            securityId: securityId,
            date: date,
            name: name,
            type: type,
            subtype: subtype,
            quantity: quantity,
            price: price,
            fees: fees,
            amount: amount,
            currencyCode: currencyCode
        )
    }
}
