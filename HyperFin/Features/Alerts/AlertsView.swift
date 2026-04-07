import SwiftUI

struct AlertsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Active Alerts") {
                    Text("No alerts yet")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Alerts")
        }
    }
}
