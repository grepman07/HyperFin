import Foundation
import SwiftUI

struct ChatMessageUI: Identifiable {
    let id: UUID
    let content: String
    let isUser: Bool
    var isStreaming: Bool

    init(id: UUID = UUID(), content: String, isUser: Bool, isStreaming: Bool = false) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.isStreaming = isStreaming
    }
}

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessageUI] = [
        ChatMessageUI(
            content: "Hi! I'm HyperFin, your AI finance coach. I run entirely on your device — your financial data never leaves your iPhone.\n\nAsk me anything about your spending, budgets, or accounts.",
            isUser: false
        )
    ]
    var inputText = ""
    var isProcessing = false

    // In production, this would be injected:
    // private let chatEngine: ChatEngine
    // private let chatMessageRepo: ChatMessageRepository
    private let sessionId = UUID()

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        messages.append(ChatMessageUI(content: text, isUser: true))

        isProcessing = true
        let responseId = UUID()
        messages.append(ChatMessageUI(id: responseId, content: "", isUser: false, isStreaming: true))

        // In production, this streams from ChatEngine:
        // Task {
        //     let context = ChatContext(sessionId: sessionId, recentMessages: ...)
        //     for try await token in chatEngine.sendMessage(text, context: context) {
        //         if let idx = messages.firstIndex(where: { $0.id == responseId }) {
        //             messages[idx] = ChatMessageUI(
        //                 id: responseId,
        //                 content: messages[idx].content + token,
        //                 isUser: false,
        //                 isStreaming: true
        //             )
        //         }
        //     }
        //     // Mark streaming complete
        //     if let idx = messages.firstIndex(where: { $0.id == responseId }) {
        //         messages[idx] = ChatMessageUI(
        //             id: responseId,
        //             content: messages[idx].content,
        //             isUser: false,
        //             isStreaming: false
        //         )
        //     }
        //     isProcessing = false
        // }

        // Placeholder until model runtime is integrated:
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if let idx = messages.firstIndex(where: { $0.id == responseId }) {
                messages[idx] = ChatMessageUI(
                    id: responseId,
                    content: "I'm ready to help with your finances! The AI engine is being set up — once Gemma 4 is integrated, I'll be able to answer questions about your spending, budgets, and accounts in real-time.",
                    isUser: false,
                    isStreaming: false
                )
            }
            isProcessing = false
        }
    }
}
