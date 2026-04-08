import Foundation
import SwiftUI
import SwiftData
import HFDomain
import HFData
import HFIntelligence
import HFShared

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
            content: "Hi! I'm HyperFin, your AI finance coach. I run entirely on your device — your financial data never leaves your iPhone.\n\nTry asking:\n- \"How much did I spend on food this month?\"\n- \"What's my balance?\"\n- \"Show my budget status\"\n- \"Spending trend for groceries\"\n- \"Any spending spikes?\"",
            isUser: false
        )
    ]
    var inputText = ""
    var isProcessing = false

    var modelContainer: ModelContainer?
    var chatEngine: ChatEngine?
    var modelStatusText: String = ""

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""
        messages.append(ChatMessageUI(content: text, isUser: true))

        isProcessing = true
        let responseId = UUID()
        messages.append(ChatMessageUI(id: responseId, content: "", isUser: false, isStreaming: true))

        Task {
            guard let engine = chatEngine else {
                updateResponse(responseId: responseId, content: "I'm having trouble connecting. Please try again.")
                isProcessing = false
                return
            }
            await streamFromEngine(engine: engine, text: text, responseId: responseId)
            isProcessing = false
        }
    }

    private func updateResponse(responseId: UUID, content: String) {
        if let idx = messages.firstIndex(where: { $0.id == responseId }) {
            messages[idx] = ChatMessageUI(
                id: responseId,
                content: content,
                isUser: false,
                isStreaming: false
            )
        }
    }

    private func streamFromEngine(engine: ChatEngine, text: String, responseId: UUID) async {
        let sessionId = UUID()
        let recentDomain = messages.suffix(4).map { msg in
            ChatMessage(
                role: msg.isUser ? .user : .assistant,
                content: msg.content,
                sessionId: sessionId
            )
        }

        // Load user profile for tone setting
        var userProfile: UserProfile?
        if let container = modelContainer {
            let ctx = container.mainContext
            let profiles = (try? ctx.fetch(FetchDescriptor<SDUserProfile>())) ?? []
            userProfile = profiles.first?.toDomain()
        }

        let context = ChatContext(sessionId: sessionId, recentMessages: recentDomain, userProfile: userProfile)

        do {
            for try await token in await engine.sendMessage(text, context: context) {
                if let idx = messages.firstIndex(where: { $0.id == responseId }) {
                    messages[idx] = ChatMessageUI(
                        id: responseId,
                        content: token,
                        isUser: false,
                        isStreaming: true
                    )
                }
            }
            // Mark streaming complete
            if let idx = messages.firstIndex(where: { $0.id == responseId }) {
                messages[idx] = ChatMessageUI(
                    id: responseId,
                    content: messages[idx].content,
                    isUser: false,
                    isStreaming: false
                )
            }
        } catch {
            updateResponse(responseId: responseId, content: "Something went wrong. Please try again.")
            HFLogger.ai.error("Chat error: \(error.localizedDescription)")
        }
    }
}
