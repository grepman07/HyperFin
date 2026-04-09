import Foundation
import SwiftUI
import SwiftData
import HFDomain
import HFData
import HFIntelligence
import HFShared

enum FeedbackRating: Sendable {
    case none, positive, negative
}

struct ChatMessageUI: Identifiable {
    let id: UUID
    let content: String
    let isUser: Bool
    /// Static help / welcome bubbles that aren't AI responses. Feedback buttons
    /// are suppressed for these since there's nothing to rate.
    let isHelp: Bool
    var isStreaming: Bool
    var rating: FeedbackRating

    init(id: UUID = UUID(), content: String, isUser: Bool, isHelp: Bool = false, isStreaming: Bool = false, rating: FeedbackRating = .none) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.isHelp = isHelp
        self.isStreaming = isStreaming
        self.rating = rating
    }
}

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessageUI] = [
        ChatMessageUI(
            content: "Hi! I'm HyperFin, your AI finance coach. I run entirely on your device — your financial data never leaves your iPhone.\n\nTry asking:\n- \"How much did I spend on food this month?\"\n- \"What's my balance?\"\n- \"Show my budget status\"\n- \"Spending trend for groceries\"\n- \"Any spending spikes?\"",
            isUser: false,
            isHelp: true
        )
    ]
    var inputText = ""
    var isProcessing = false

    var modelContainer: ModelContainer?
    var chatEngine: ChatEngine?
    var telemetryLogger: TelemetryLogger?
    var modelStatusText: String = ""

    /// Stable chat session ID — survives across messages in the same chat
    /// view so server-side analytics can stitch follow-ups together. Rotated
    /// if you ever add a "start new chat" button.
    private let sessionId = UUID()

    /// Map ChatMessageUI.id → telemetry event id so `rateFeedback` knows which
    /// row in the telemetry queue to update.
    private var telemetryEventIds: [UUID: UUID] = [:]

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

    func rateFeedback(messageId: UUID, rating: FeedbackRating) {
        guard let idx = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[idx].rating = rating

        // Find the user query that preceded this response
        let userQuery = messages.prefix(idx).last(where: { $0.isUser })?.content ?? ""

        let ratingStr = rating == .positive ? "positive" : "negative"
        let responsePreview = String(self.messages[idx].content.prefix(80))
        HFLogger.ai.info("Feedback: \(ratingStr) | query: \(userQuery) | response: \(responsePreview)")

        // Propagate to the telemetry queue so uploaders see the updated rating
        if let logger = telemetryLogger, let eventId = telemetryEventIds[messageId] {
            let telemetryRating: TelemetryFeedbackRating = switch rating {
            case .positive: .positive
            case .negative: .negative
            case .none: .none
            }
            Task { await logger.updateFeedback(eventId: eventId, rating: telemetryRating) }
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

        let start = Date()

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

            // Emit telemetry (no-op if user has not opted in). We read the
            // intent that ChatEngine actually resolved — which may have come
            // from the LLM classifier when regex missed — so the telemetry
            // event is tagged with the real intent rather than re-parsed
            // "unknown".
            let resolvedIntent = await engine.lastResolvedIntent()
            await logTelemetry(
                query: text,
                responseId: responseId,
                latencyMs: Int(Date().timeIntervalSince(start) * 1000),
                resolvedIntent: resolvedIntent
            )
        } catch {
            updateResponse(responseId: responseId, content: "Something went wrong. Please try again.")
            HFLogger.ai.error("Chat error: \(error.localizedDescription)")
        }
    }

    // MARK: - Telemetry

    private func logTelemetry(
        query: String,
        responseId: UUID,
        latencyMs: Int,
        resolvedIntent: ChatIntent?
    ) async {
        guard let logger = telemetryLogger else { return }
        guard let idx = messages.firstIndex(where: { $0.id == responseId }) else { return }
        let responseText = messages[idx].content

        let (intentStr, category, period) = telemetryFields(for: resolvedIntent ?? .unknown(rawQuery: query))

        let eventId = await logger.log(
            queryRaw: query,
            responseRaw: responseText,
            intent: intentStr,
            category: category,
            period: period,
            latencyMs: latencyMs,
            sessionId: sessionId
        )
        if let eventId {
            telemetryEventIds[responseId] = eventId
        }
    }

    /// Derive the flat (intent, category, period) tuple from a parsed
    /// `ChatIntent`. Mirrors the classification labels the server expects.
    private func telemetryFields(for intent: ChatIntent) -> (String, String?, String?) {
        switch intent {
        case .greeting:
            return ("greeting", nil, nil)
        case .spendingQuery(let category, let merchant, let period):
            return ("spending", category ?? merchant, period.serverLabel)
        case .budgetStatus(let category):
            return ("budget", category, nil)
        case .accountBalance:
            return ("balance", nil, nil)
        case .trendQuery(let category, _):
            return ("trend", category, nil)
        case .anomalyCheck(let category, let period):
            return ("anomaly", category, period.serverLabel)
        case .transactionSearch(let merchant, _, _):
            return ("transaction_search", merchant, nil)
        case .generalAdvice:
            return ("advice", nil, nil)
        case .unknown:
            return ("unknown", nil, nil)
        }
    }
}

private extension DatePeriod {
    /// Stable machine-readable label for the server analytics. Uses snake_case
    /// so it matches the values the classification prompt emits.
    var serverLabel: String {
        switch self {
        case .today: return "today"
        case .thisWeek: return "this_week"
        case .thisMonth: return "this_month"
        case .lastMonth: return "last_month"
        case .last30Days: return "last_30_days"
        case .last90Days: return "last_90_days"
        case .lastNMonths(let n): return "last_\(n)_months"
        case .custom: return "custom"
        }
    }
}
