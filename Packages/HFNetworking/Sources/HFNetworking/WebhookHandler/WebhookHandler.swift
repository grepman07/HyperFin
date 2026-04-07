import Foundation
import HFShared

public enum WebhookType: String, Sendable {
    case transactionsSync = "TRANSACTIONS"
    case itemUpdate = "ITEM"
    case unknown
}

public struct WebhookPayload: Sendable {
    public let type: WebhookType
    public let itemId: String?

    public init(type: WebhookType, itemId: String?) {
        self.type = type
        self.itemId = itemId
    }
}

public struct WebhookHandler: Sendable {
    public init() {}

    public func parse(userInfo: [AnyHashable: Any]) -> WebhookPayload? {
        guard let typeString = userInfo["webhook_type"] as? String else { return nil }
        let type = WebhookType(rawValue: typeString) ?? .unknown
        let itemId = userInfo["item_id"] as? String

        HFLogger.sync.info("Received webhook: \(typeString)")
        return WebhookPayload(type: type, itemId: itemId)
    }
}
