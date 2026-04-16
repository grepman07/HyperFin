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

// MARK: - UI-Boundary Sanitizer

private extension String {
    /// Last-resort cleanup that runs at the UI boundary, right before text
    /// lands in a chat bubble. This catches ANY ChatML / special-token
    /// marker that the inference engine failed to strip — including partial
    /// fragments that arrive across chunk boundaries, full `<|im_end|>`
    /// tokens, or unusual Unicode representations of the pipe/angle chars.
    ///
    /// The regex approach is intentionally broad: it matches the generic
    /// `<|…|>` pattern used by Qwen, Gemma, LLaMA, and most open-weight
    /// models, so we don't need to enumerate every possible marker.
    var sanitizedForDisplay: String {
        var result = self

        // 1. Remove any fully-formed <|…|> control markers anywhere in the
        //    string (e.g. <|im_end|>, <|im_start|>, <|endoftext|>).
        result = result.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: "",
            options: .regularExpression
        )

        // 2. Remove a trailing PARTIAL marker at the end of the string.
        //    Matches `<|` followed by word/punctuation chars but no closing
        //    `|>`, anchored to end-of-string. Handles fragments like
        //    `<|im_end`, `<|im_`, `<|endoftext` that the inference engine
        //    may still be accumulating when the stream terminates.
        result = result.replacingOccurrences(
            of: #"<\|[\w|]*$"#,
            with: "",
            options: .regularExpression
        )

        // 3. Trim trailing whitespace/newlines left behind after removal.
        //    The model often emits `\n\n<|im_end|>` so stripping the
        //    marker leaves dangling blank lines.
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
    /// Static welcome bubble shown when there's no prior history (fresh install
    /// or after "Clear chat"). Not persisted to SwiftData — it's UI copy, not a
    /// real turn, hence `isHelp: true` which also suppresses feedback buttons.
    static func welcomeBubble() -> ChatMessageUI {
        ChatMessageUI(
            content: "Hi! I'm HyperFin, your AI finance coach. I run entirely on your device — your financial data never leaves your iPhone.\n\nTry asking:\n- \"How much did I spend on food this month?\"\n- \"What's my balance?\"\n- \"Show my budget status\"\n- \"Spending trend for groceries\"\n- \"Any spending spikes?\"",
            isUser: false,
            isHelp: true
        )
    }

    var messages: [ChatMessageUI] = [welcomeBubble()]
    var inputText = ""
    var isProcessing = false

    var modelContainer: ModelContainer?
    var chatEngine: ChatEngine?
    var telemetryLogger: TelemetryLogger?
    var modelStatusText: String = ""

    /// Session ID for the CURRENT app launch. Rotates on every fresh
    /// ChatViewModel construction (cold launch) so server-side analytics
    /// don't artificially stitch unrelated conversations across launches.
    /// Persisted messages carry the session ID they were born under, which
    /// is preserved in SwiftData; only NEW messages use this one.
    private let sessionId = UUID()

    /// Map ChatMessageUI.id → telemetry event id so `rateFeedback` knows which
    /// row in the telemetry queue to update.
    private var telemetryEventIds: [UUID: UUID] = [:]

    // MARK: - History Persistence

    /// Load any chat history within the retention window and rehydrate the
    /// on-screen `messages` array. Also purges anything older than the
    /// retention window in the same pass. Called from ChatView.onAppear
    /// once the modelContainer has been wired up.
    ///
    /// If no history exists (fresh install, or everything purged), the
    /// welcome bubble is shown instead.
    func loadHistory() {
        guard let container = modelContainer else {
            // No container yet — nothing to load. The welcome bubble is
            // already the default; leave it.
            return
        }
        let ctx = container.mainContext
        let cutoff = Date().addingTimeInterval(
            -Double(HFConstants.Chat.historyRetentionDays) * 86_400
        )

        // Purge expired rows first. Do it in a separate fetch so the
        // retention sweep doesn't compete with the rehydration predicate
        // inside SwiftData's query planner.
        do {
            let expiredPredicate = #Predicate<SDChatMessage> { $0.timestamp < cutoff }
            let expiredDescriptor = FetchDescriptor<SDChatMessage>(predicate: expiredPredicate)
            let expired = try ctx.fetch(expiredDescriptor)
            if !expired.isEmpty {
                for row in expired { ctx.delete(row) }
                try ctx.save()
                HFLogger.ai.info("Chat history retention: purged \(expired.count) expired message(s)")
            }
        } catch {
            HFLogger.ai.warning("Chat retention purge failed: \(error.localizedDescription)")
        }

        // Load the surviving window in chronological order.
        do {
            let livePredicate = #Predicate<SDChatMessage> { $0.timestamp >= cutoff }
            var liveDescriptor = FetchDescriptor<SDChatMessage>(predicate: livePredicate)
            liveDescriptor.sortBy = [SortDescriptor(\SDChatMessage.timestamp, order: .forward)]
            let rows = try ctx.fetch(liveDescriptor)

            if rows.isEmpty {
                messages = [Self.welcomeBubble()]
            } else {
                messages = rows.map { row in
                    ChatMessageUI(
                        id: row.id,
                        content: row.content,
                        isUser: row.roleRaw == MessageRole.user.rawValue,
                        isHelp: false,
                        isStreaming: false
                    )
                }
            }
        } catch {
            HFLogger.ai.error("Chat history load failed: \(error.localizedDescription)")
            messages = [Self.welcomeBubble()]
        }
    }

    /// Wipe every persisted chat message and reset the on-screen view to
    /// just the welcome bubble. Triggered by the toolbar clear button.
    /// Does NOT touch telemetry events — ratings already in the upload
    /// queue keep their payloads intact.
    func clearHistory() {
        guard let container = modelContainer else {
            messages = [Self.welcomeBubble()]
            telemetryEventIds.removeAll()
            return
        }
        let ctx = container.mainContext
        do {
            let all = try ctx.fetch(FetchDescriptor<SDChatMessage>())
            for row in all { ctx.delete(row) }
            try ctx.save()
            HFLogger.ai.info("Chat history cleared (\(all.count) messages deleted)")
        } catch {
            HFLogger.ai.error("Chat clear failed: \(error.localizedDescription)")
        }
        messages = [Self.welcomeBubble()]
        telemetryEventIds.removeAll()
    }

    /// Insert a single chat turn into SwiftData. Called twice per message
    /// exchange: once for the user query (immediately on send, so it
    /// survives a mid-stream crash) and once for the assistant response
    /// after streaming completes.
    private func persistMessage(id: UUID, content: String, isUser: Bool) {
        guard let container = modelContainer else { return }
        let ctx = container.mainContext
        let domain = ChatMessage(
            id: id,
            role: isUser ? .user : .assistant,
            content: content,
            timestamp: Date(),
            sessionId: sessionId
        )
        ctx.insert(SDChatMessage(from: domain))
        do {
            try ctx.save()
        } catch {
            HFLogger.ai.error("Failed to persist chat message: \(error.localizedDescription)")
        }
    }

    // MARK: - Message Flow

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        inputText = ""

        // If the list is still showing ONLY the welcome bubble, drop it —
        // the user is starting a real conversation and we don't want the
        // static help card mixed into persisted history.
        if messages.count == 1, messages[0].isHelp {
            messages.removeAll()
        }

        let userId = UUID()
        messages.append(ChatMessageUI(id: userId, content: text, isUser: true))
        persistMessage(id: userId, content: text, isUser: true)

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
                    // UI-boundary sanitize: strip any ChatML control tokens
                    // that the inference engine failed to catch. This is the
                    // belt-and-suspenders layer — InferenceEngine has its own
                    // sanitize, but if a token slips through (fragmentation,
                    // Unicode edge case, stale build cache), this catches it
                    // before it ever reaches the Text() view.
                    messages[idx] = ChatMessageUI(
                        id: responseId,
                        content: token.sanitizedForDisplay,
                        isUser: false,
                        isStreaming: true
                    )
                }
            }
            // Mark streaming complete — apply one final sanitize pass on the
            // accumulated content in case the last yielded delta carried a
            // trailing partial marker.
            if let idx = messages.firstIndex(where: { $0.id == responseId }) {
                let cleanContent = messages[idx].content.sanitizedForDisplay
                messages[idx] = ChatMessageUI(
                    id: responseId,
                    content: cleanContent,
                    isUser: false,
                    isStreaming: false
                )
                // Persist the finalized assistant response. We wait until
                // streaming is done so SwiftData doesn't see half-formed
                // content — the UI replaces the bubble on every delta, so
                // writing per-delta would churn the store needlessly.
                persistMessage(
                    id: responseId,
                    content: cleanContent,
                    isUser: false
                )
            }

            // Emit telemetry (no-op if user has not opted in). With the
            // tool-calling pipeline, "intent" is represented by the set of
            // tools the planner chose — join them with "+" so a single
            // string column on the server can still carry multi-tool turns.
            let toolNames = await engine.lastToolNames()
            await logTelemetry(
                query: text,
                responseId: responseId,
                latencyMs: Int(Date().timeIntervalSince(start) * 1000),
                toolNames: toolNames
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
        toolNames: [String]
    ) async {
        guard let logger = telemetryLogger else { return }
        guard let idx = messages.firstIndex(where: { $0.id == responseId }) else { return }
        let responseText = messages[idx].content

        // The "intent" column now carries either the single tool name or
        // a "+"-joined list for multi-tool plans. Empty plans (greetings,
        // general advice) log as "none" so they're still distinguishable
        // from failed classifications in server-side dashboards.
        let intentStr: String
        if toolNames.isEmpty {
            intentStr = "none"
        } else if toolNames.count == 1 {
            intentStr = toolNames[0]
        } else {
            intentStr = toolNames.joined(separator: "+")
        }

        let eventId = await logger.log(
            queryRaw: query,
            responseRaw: responseText,
            intent: intentStr,
            category: nil,
            period: nil,
            latencyMs: latencyMs,
            sessionId: sessionId
        )
        if let eventId {
            telemetryEventIds[responseId] = eventId
        }
    }
}
