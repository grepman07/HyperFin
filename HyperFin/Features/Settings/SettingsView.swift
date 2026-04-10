import SwiftUI
import SwiftData
import HFData
import HFDomain
import HFShared
import HFIntelligence

struct SettingsView: View {
    @Query(sort: \SDTransaction.date, order: .reverse) private var transactions: [SDTransaction]
    @Query(sort: \SDCategory.name) private var categories: [SDCategory]
    @Query(sort: \SDAccount.institutionName) private var accounts: [SDAccount]

    @Query private var profiles: [SDUserProfile]

    @State private var showExportShare = false
    @State private var exportURL: URL?
    @State private var isExporting = false

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink {
                        AlertsView()
                    } label: {
                        Label("Notifications", systemImage: "bell.fill")
                    }
                }

                Section("Security") {
                    NavigationLink {
                        Text("Security Settings")
                    } label: {
                        Label("Face ID & Passcode", systemImage: "faceid")
                    }
                }

                Section("Data") {
                    Button {
                        exportCSV()
                    } label: {
                        HStack {
                            Label("Export Data (CSV)", systemImage: "square.and.arrow.up")
                            Spacer()
                            if isExporting {
                                ProgressView()
                            } else {
                                Text("\(transactions.count) transactions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(transactions.isEmpty || isExporting)

                    NavigationLink {
                        TransactionsView()
                    } label: {
                        Label("All Transactions", systemImage: "list.bullet")
                    }
                }

                Section("AI") {
                    NavigationLink {
                        AIModelView()
                    } label: {
                        HStack {
                            Label("On-Device AI", systemImage: "brain")
                            Spacer()
                            Text(ModelManager.isMLXSupported ? HFConstants.AI.modelShortDisplayName : "Simulator")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        HStack {
                            Label("Cloud Chat", systemImage: "cloud.fill")
                            Spacer()
                            Text(profiles.first?.cloudChatOptIn == true ? "On" : "Off")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        TonePickerView(profile: profiles.first)
                    } label: {
                        HStack {
                            Label("Chat Tone", systemImage: currentTone.icon)
                            Spacer()
                            Text(currentTone.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Privacy") {
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text("Privacy Status")
                                .font(.subheadline.bold())
                            Text("All AI processing on-device. No financial data on servers.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        PrivacySettingsView()
                    } label: {
                        HStack {
                            Label("Data Sharing", systemImage: "hand.raised.fill")
                            Spacer()
                            Text(profiles.first?.telemetryOptIn == true ? "On" : "Off")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Text("HyperFin v1.0.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showExportShare) {
                if let url = exportURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    private var currentTone: ChatTone {
        guard let profile = profiles.first else { return .professional }
        return ChatTone(rawValue: profile.chatToneRaw) ?? .professional
    }

    private func exportCSV() {
        isExporting = true

        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.accountName) })

        var csv = "Date,Amount,Category,Merchant,Description,Account\n"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for txn in transactions {
            let date = formatter.string(from: txn.date)
            let amount = "\(txn.amount)"
            let category = txn.categoryId.flatMap { categoryMap[$0] } ?? ""
            let merchant = (txn.merchantName ?? "").replacingOccurrences(of: ",", with: " ")
            let description = txn.originalDescription.replacingOccurrences(of: ",", with: " ")
            let account = accountMap[txn.accountId] ?? ""
            csv += "\(date),\(amount),\(category),\(merchant),\(description),\(account)\n"
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("HyperFin_Export_\(formatter.string(from: Date())).csv")

        do {
            try csv.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            showExportShare = true
            HFLogger.general.info("CSV export created: \(transactions.count) transactions")
        } catch {
            HFLogger.general.error("CSV export failed: \(error.localizedDescription)")
        }

        isExporting = false
    }
}

struct TonePickerView: View {
    @Environment(\.modelContext) private var modelContext
    let profile: SDUserProfile?

    private var selectedTone: ChatTone {
        guard let profile else { return .professional }
        return ChatTone(rawValue: profile.chatToneRaw) ?? .professional
    }

    var body: some View {
        List {
            Section {
                ForEach(ChatTone.allCases, id: \.self) { tone in
                    Button {
                        setTone(tone)
                    } label: {
                        HStack {
                            Image(systemName: tone.icon)
                                .foregroundStyle(.blue)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tone.displayName)
                                    .foregroundStyle(.primary)
                                Text(toneDescription(tone))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedTone == tone {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            } footer: {
                Text("Controls how HyperFin responds to your financial questions.")
            }
        }
        .navigationTitle("Chat Tone")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toneDescription(_ tone: ChatTone) -> String {
        switch tone {
        case .professional: "Clear, businesslike responses"
        case .friendly: "Warm, casual, and encouraging"
        case .funny: "Witty with playful financial humor"
        case .strict: "No-nonsense accountability coach"
        }
    }

    private func setTone(_ tone: ChatTone) {
        if let profile {
            profile.chatToneRaw = tone.rawValue
            try? modelContext.save()
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
