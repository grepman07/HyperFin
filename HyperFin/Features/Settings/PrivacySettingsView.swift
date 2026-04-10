import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared
import HFIntelligence

struct PrivacySettingsView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [SDUserProfile]

    @State private var telemetryOptIn = false
    @State private var showDisableConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showLearnMore = false
    @State private var isWorking = false
    @State private var statusMessage: String?

    // Cloud chat (opt-in tier). Retrieval always stays on-device; only the
    // anonymized query + pre-aggregated tool result reach the server.
    @State private var cloudChatOptIn = false
    @State private var showCloudDisableConfirm = false
    @State private var showCloudLearnMore = false

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your data stays on your device")
                            .font(.subheadline.bold())
                        Text("HyperFin's AI runs entirely on your iPhone. No financial data ever reaches our servers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { telemetryOptIn },
                    set: { newValue in
                        if !newValue && telemetryOptIn {
                            // User is trying to turn it off — confirm first
                            showDisableConfirm = true
                        } else {
                            telemetryOptIn = newValue
                            persistTelemetryOptIn(newValue)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share anonymized chats")
                            .font(.body.weight(.medium))
                        Text("Help us improve HyperFin's AI. Your name and account numbers are stripped on-device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isWorking)

                Button("Learn what's shared") { showLearnMore = true }
                    .font(.subheadline)
            } header: {
                Text("Improve HyperFin")
            } footer: {
                Text("Default is off. You can turn this on or off at any time. Turning it off also deletes anything we've already collected.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { cloudChatOptIn },
                    set: { newValue in
                        if !newValue && cloudChatOptIn {
                            // Confirm before turning off — matches telemetry UX.
                            showCloudDisableConfirm = true
                        } else {
                            cloudChatOptIn = newValue
                            persistCloudChatOptIn(newValue)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smarter cloud answers")
                            .font(.body.weight(.medium))
                        Text("Use Claude Haiku for chat replies. Your transactions stay on-device — only your question and its summary totals are sent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isWorking)

                Button("Learn what's shared with cloud chat") { showCloudLearnMore = true }
                    .font(.subheadline)
            } header: {
                Text("Cloud chat (beta)")
            } footer: {
                Text("Default is off. When off, chat runs entirely on your iPhone using the local model.")
            }

            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack {
                        Label("Delete my telemetry data", systemImage: "trash")
                        Spacer()
                        if isWorking {
                            ProgressView()
                        }
                    }
                }
                .disabled(isWorking)
            } footer: {
                Text("Removes anonymized chats from your device and requests deletion from our servers. Your financial data is never touched.")
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadFromProfile() }
        .sheet(isPresented: $showLearnMore) {
            TelemetryLearnMoreDetailSheet()
        }
        .sheet(isPresented: $showCloudLearnMore) {
            CloudChatLearnMoreDetailSheet()
        }
        .confirmationDialog(
            "Turn off sharing?",
            isPresented: $showDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("Turn Off & Delete", role: .destructive) {
                telemetryOptIn = false
                persistTelemetryOptIn(false)
                Task { await purgeTelemetryData(reason: "Sharing disabled. Local queue purged and deletion requested.") }
            }
            Button("Keep Sharing", role: .cancel) {
                // no-op — the Toggle binding already prevented the change
            }
        } message: {
            Text("Any anonymized chats we've collected will be deleted from your device, and we'll request deletion from our servers.")
        }
        .confirmationDialog(
            "Turn off cloud chat?",
            isPresented: $showCloudDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("Turn Off", role: .destructive) {
                cloudChatOptIn = false
                persistCloudChatOptIn(false)
                statusMessage = "Cloud chat disabled. Responses now generated on-device."
            }
            Button("Keep On", role: .cancel) {}
        } message: {
            Text("Chat responses will be generated on your iPhone using the local model. Nothing will be sent to the cloud.")
        }
        .confirmationDialog(
            "Delete telemetry data?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                Task { await purgeTelemetryData(reason: "Telemetry data deleted.") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes anonymized chats from your device and requests deletion from our servers. Your financial data is not affected.")
        }
    }

    // MARK: - State helpers

    private func loadFromProfile() {
        telemetryOptIn = profiles.first?.telemetryOptIn ?? false
        cloudChatOptIn = profiles.first?.cloudChatOptIn ?? false
    }

    private func persistTelemetryOptIn(_ value: Bool) {
        let existing = profiles.first
        if let existing {
            existing.telemetryOptIn = value
            existing.telemetryOptInDate = value ? Date() : nil
        } else {
            let profile = UserProfile(
                telemetryOptIn: value,
                telemetryOptInDate: value ? Date() : nil
            )
            modelContext.insert(SDUserProfile(from: profile))
        }
        try? modelContext.save()
        HFLogger.telemetry.info("Privacy toggle set. telemetryOptIn=\(value)")
    }

    private func persistCloudChatOptIn(_ value: Bool) {
        let existing = profiles.first
        if let existing {
            existing.cloudChatOptIn = value
            existing.cloudChatOptInDate = value ? Date() : nil
        } else {
            let profile = UserProfile(
                cloudChatOptIn: value,
                cloudChatOptInDate: value ? Date() : nil
            )
            modelContext.insert(SDUserProfile(from: profile))
        }
        try? modelContext.save()
        HFLogger.cloudChat.info("Privacy toggle set. cloudChatOptIn=\(value)")
    }

    private func purgeTelemetryData(reason: String) async {
        isWorking = true
        defer { isWorking = false }
        let logger = dependencies.telemetryLogger
        await logger.purgeLocalQueue()
        statusMessage = reason
    }
}

private struct TelemetryLearnMoreDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("What we collect", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    Text("• The questions you ask (anonymized)\n• The AI's answers (anonymized)\n• Your thumbs up / thumbs down ratings\n• Response timing and the model version\n• A random install ID — NOT your email or account")
                        .font(.callout)

                    Divider()

                    Label("What we strip out", systemImage: "xmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text("• Your name\n• Email addresses\n• Account numbers (last-4 and full)\n• Social security numbers\n• Plaid institution tokens")
                        .font(.callout)

                    Divider()

                    Label("Example", systemImage: "text.bubble.fill")
                        .font(.headline)

                    Text("Raw:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\"How much did Kevin spend at Uber on card ****1234?\"")
                        .font(.callout)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("Uploaded:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\"How much did [NAME] spend at Uber on card [ACCT]?\"")
                        .font(.callout)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Divider()

                    Label("Your control", systemImage: "hand.raised.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    Text("You can turn this off at any time. When you do, we delete anything we've already collected — both from your device and from our servers.")
                        .font(.callout)
                }
                .padding()
            }
            .navigationTitle("What's shared")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct CloudChatLearnMoreDetailSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("How cloud chat works", systemImage: "cloud.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    Text("When you ask a question, HyperFin still looks up your transactions entirely on your iPhone. We only send a short summary — your question and the totals we computed — to Anthropic's Claude Haiku model, which writes the reply.")
                        .font(.callout)

                    Divider()

                    Label("What is sent", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    Text("• Your question (with your name stripped out)\n• Pre-computed totals such as \"$142.50 spent on Food & Dining this month\"\n• The top 5 merchants by amount for the period\n• A random install ID for rate limiting")
                        .font(.callout)

                    Divider()

                    Label("What is NOT sent", systemImage: "xmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text("• Individual transaction rows\n• Merchant descriptions or memos\n• Account numbers (full or last-4)\n• Your name or email\n• Plaid access tokens\n• Balances you didn't ask about")
                        .font(.callout)

                    Divider()

                    Label("Example", systemImage: "text.bubble.fill")
                        .font(.headline)

                    Text("Raw question:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\"Hey, did I overspend on food this month?\"")
                        .font(.callout)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("Sent to Claude:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\"Hey, did I overspend on food this month?\"\n\nHere is the data:\n{\"total\":\"$142.50\",\"count\":18,\"category\":\"Food & Dining\",\"period\":\"this_month\",\"top_merchants\":[{\"name\":\"Chipotle\",\"amount\":\"$48.12\"}]}")
                        .font(.callout.monospaced())
                        .padding(10)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Divider()

                    Label("Your control", systemImage: "hand.raised.fill")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    Text("You can turn cloud chat off at any time. When off, replies are generated on your iPhone using the local model.")
                        .font(.callout)
                }
                .padding()
            }
            .navigationTitle("What's shared with cloud chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
