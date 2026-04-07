import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink {
                        Text("Profile")
                    } label: {
                        Label("Profile", systemImage: "person.fill")
                    }

                    NavigationLink {
                        Text("Notifications")
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

                    NavigationLink {
                        Text("Two-Factor Auth")
                    } label: {
                        Label("Two-Factor Authentication", systemImage: "lock.shield.fill")
                    }
                }

                Section("Data") {
                    Button {
                        // Export CSV
                    } label: {
                        Label("Export Data (CSV)", systemImage: "square.and.arrow.up")
                    }

                    NavigationLink {
                        Text("Manage Categories")
                    } label: {
                        Label("Categories", systemImage: "tag.fill")
                    }
                }

                Section("AI") {
                    NavigationLink {
                        Text("AI Model Info")
                    } label: {
                        Label("On-Device AI", systemImage: "brain")
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
        }
    }
}
