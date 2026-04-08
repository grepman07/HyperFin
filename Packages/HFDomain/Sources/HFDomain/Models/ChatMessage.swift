import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var role: MessageRole
    public var content: String
    public var timestamp: Date
    public var sessionId: UUID
    public var isStreaming: Bool

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        sessionId: UUID,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.isStreaming = isStreaming
    }
}
