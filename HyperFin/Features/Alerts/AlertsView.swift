import SwiftUI
import SwiftData
import HFData
import HFDomain

struct AlertsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var alertConfigs: [SDAlertConfig]

    var body: some View {
        NavigationStack {
            List {
                Section("Spending Alerts") {
                    alertToggle(type: .budgetThreshold, title: "Budget Warning (80%)",
                                description: "Get notified when spending reaches 80% of a category budget",
                                icon: "exclamationmark.triangle.fill", color: .orange)

                    alertToggle(type: .budgetExceeded, title: "Budget Exceeded",
                                description: "Alert when you go over budget in any category",
                                icon: "xmark.octagon.fill", color: .red)

                    alertToggle(type: .unusualTransaction, title: "Unusual Transactions",
                                description: "Flag transactions significantly above your average",
                                icon: "sparkle.magnifyingglass", color: .purple)
                }

                Section("Summaries") {
                    alertToggle(type: .weeklySummary, title: "Weekly Summary",
                                description: "Spending recap delivered every Monday at 9am",
                                icon: "calendar.badge.clock", color: .blue)
                }

                Section {
                    Button {
                        Task {
                            let granted = await NotificationManager.shared.requestPermission()
                            if !granted {
                                // Show settings prompt
                            }
                        }
                    } label: {
                        Label("Notification Permissions", systemImage: "bell.badge")
                    }
                }
            }
            .navigationTitle("Alerts")
        }
    }

    private func alertToggle(type: AlertType, title: String, description: String, icon: String, color: Color) -> some View {
        let config = alertConfigs.first { $0.alertTypeRaw == type.rawValue }
        let isOn = config?.isEnabled ?? true

        return Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                if let existing = config {
                    existing.isEnabled = newValue
                } else {
                    let newConfig = SDAlertConfig(from: AlertConfig(alertType: type, isEnabled: newValue))
                    modelContext.insert(newConfig)
                }
                try? modelContext.save()
            }
        )) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
