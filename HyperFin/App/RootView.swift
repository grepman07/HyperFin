import SwiftUI
import SwiftData
import HFData

struct RootView: View {
    let dependencies: AppDependencies
    @State private var isAuthenticated = false
    @State private var hasCompletedOnboarding = false
    @State private var selectedTab: Tab = .chat
    @Query private var profiles: [SDUserProfile]

    enum Tab: String, CaseIterable {
        case chat = "Chat"
        case dashboard = "Dashboard"
        case budgets = "Budgets"
        case accounts = "Accounts"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .chat: "message.fill"
            case .dashboard: "chart.pie.fill"
            case .budgets: "dollarsign.circle.fill"
            case .accounts: "building.columns.fill"
            case .settings: "gearshape.fill"
            }
        }
    }

    var body: some View {
        Group {
            if !isAuthenticated {
                LockScreenView(isAuthenticated: $isAuthenticated)
            } else if !hasCompletedOnboarding {
                OnboardingView(isComplete: $hasCompletedOnboarding)
            } else {
                mainTabView
            }
        }
        .onChange(of: profiles.count) {
            if let profile = profiles.first, profile.onboardingCompleted {
                hasCompletedOnboarding = true
            }
        }
        .onAppear {
            if let profile = profiles.first, profile.onboardingCompleted {
                hasCompletedOnboarding = true
            }
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases, id: \.self) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label(tab.rawValue, systemImage: tab.icon)
                    }
                    .tag(tab)
            }
        }
        .tint(.blue)
        .environment(dependencies)
    }

    @ViewBuilder
    private func tabContent(for tab: Tab) -> some View {
        switch tab {
        case .chat:
            ChatView()
        case .dashboard:
            DashboardView()
        case .budgets:
            BudgetsView()
        case .accounts:
            AccountsView()
        case .settings:
            SettingsView()
        }
    }
}
