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
                            persistOptIn(newValue)
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
        .confirmationDialog(
            "Turn off sharing?",
            isPresented: $showDisableConfirm,
            titleVisibility: .visible
        ) {
            Button("Turn Off & Delete", role: .destructive) {
                telemetryOptIn = false
                persistOptIn(false)
                Task { await purgeTelemetryData(reason: "Sharing disabled. Local queue purged and deletion requested.") }
            }
            Button("Keep Sharing", role: .cancel) {
                // no-op — the Toggle binding already prevented the change
            }
        } message: {
            Text("Any anonymized chats we've collected will be deleted from your device, and we'll request deletion from our servers.")
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
    }

    private func persistOptIn(_ value: Bool) {
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
