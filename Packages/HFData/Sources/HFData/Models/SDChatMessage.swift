import Foundation
import SwiftData
import HFDomain

@Model
public final class SDChatMessage {
    @Attribute(.unique) public var id: UUID
    public var roleRaw: String
    public var content: String
    public var timestamp: Date
    public var sessionId: UUID

    public init(from domain: ChatMessage) {
        self.id = domain.id
        self.roleRaw = domain.role.rawValue
        self.content = domain.content
        self.timestamp = domain.timestamp
        self.sessionId = domain.sessionId
    }

    public func toDomain() -> ChatMessage {
        ChatMessage(
            id: id,
            role: MessageRole(rawValue: roleRaw) ?? .user,
            content: content,
            timestamp: timestamp,
            sessionId: sessionId
        )
    }
}
