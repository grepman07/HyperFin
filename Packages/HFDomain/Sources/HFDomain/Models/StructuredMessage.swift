import Foundation

/// Platform-independent chat message for prompt assembly.
///
/// Mirrors the role/content structure that LLM chat templates expect
/// (system, user, assistant) without importing any inference framework.
/// `PromptAssembler` builds arrays of these; `InferenceEngine` maps them
/// to the framework-specific type (e.g. MLX-Swift `Chat.Message`) right
/// before calling `applyChatTemplate`.
public struct StructuredMessage: Sendable {
    public enum Role: Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    // MARK: - Convenience factories

    public static func system(_ content: String) -> StructuredMessage {
        StructuredMessage(role: .system, content: content)
    }

    public static func user(_ content: String) -> StructuredMessage {
        StructuredMessage(role: .user, content: content)
    }

    public static func assistant(_ content: String) -> StructuredMessage {
        StructuredMessage(role: .assistant, content: content)
    }
}
