import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppDependencies.self) private var dependencies
    @FocusState private var isInputFocused: Bool
    @State private var viewModel = ChatViewModel()
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                ChatBubbleView(message: message) { rating in
                                    viewModel.rateFeedback(messageId: message.id, rating: rating)
                                }
                                .id(message.id)
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .onChange(of: viewModel.messages.count) {
                        if let last = viewModel.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                chatInput
            }
            .navigationTitle("HyperFin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showClearConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.callout)
                    }
                    // Disable when there's nothing beyond the welcome bubble,
                    // or while a response is streaming (avoid partial state).
                    .disabled(viewModel.messages.allSatisfy(\.isHelp) || viewModel.isProcessing)
                }
            }
            .confirmationDialog(
                "Clear chat history?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All Messages", role: .destructive) {
                    viewModel.clearHistory()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This permanently deletes all messages. This can't be undone.")
            }
            .onAppear {
                viewModel.modelContainer = modelContext.container
                viewModel.chatEngine = dependencies.chatEngine
                viewModel.telemetryLogger = dependencies.telemetryLogger
                viewModel.loadHistory()
            }
            .onAppear {
                // AppDependencies.init kicks off the model download at launch
                // via a detached Task so it isn't tied to any view lifecycle.
                // If for any reason the model still isn't loaded here, we
                // start another detached Task — using `.task {}` would bind
                // the download to ChatView's lifecycle and navigating to
                // another tab would cancel it mid-download.
                let manager = dependencies.modelManager
                Task.detached {
                    let status = await manager.currentStatus
                    if case .loaded = status { return }
                    try? await manager.loadModel()
                }
            }
        }
    }

    private var chatInput: some View {
        HStack(spacing: 12) {
            TextField("Ask about your finances...", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .onSubmit {
                    viewModel.sendMessage()
                    isInputFocused = false
                }

            Button {
                viewModel.sendMessage()
                isInputFocused = false
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(viewModel.inputText.isEmpty ? .gray : .blue)
            }
            .disabled(viewModel.inputText.isEmpty || viewModel.isProcessing)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}

struct ChatBubbleView: View {
    let message: ChatMessageUI
    var onRate: ((FeedbackRating) -> Void)?

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(LocalizedStringKey(message.content))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(message.isUser ? Color.blue : Color(.systemGray5))
                    .foregroundStyle(message.isUser ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                if message.isStreaming {
                    ProgressView()
                        .scaleEffect(0.7)
                }

                // Feedback buttons for completed AI responses only —
                // not for static help/welcome bubbles.
                if !message.isUser && !message.isStreaming && !message.content.isEmpty && !message.isHelp {
                    feedbackButtons
                }
            }

            if !message.isUser { Spacer(minLength: 60) }
        }
    }

    private var feedbackButtons: some View {
        HStack(spacing: 12) {
            Button {
                onRate?(message.rating == .positive ? .none : .positive)
            } label: {
                Image(systemName: message.rating == .positive ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.caption)
                    .foregroundStyle(message.rating == .positive ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                onRate?(message.rating == .negative ? .none : .negative)
            } label: {
                Image(systemName: message.rating == .negative ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.caption)
                    .foregroundStyle(message.rating == .negative ? .red : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }
}
