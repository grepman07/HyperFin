import SwiftUI
import SwiftData
import HFData
import HFShared

@main
struct HyperFinApp: App {
    let dependencies: AppDependencies
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastForegroundAt: Date = Date()

    init() {
        dependencies = AppDependencies()
        BackgroundTaskManager.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
                .onAppear {
                    Task {
                        let _ = await NotificationManager.shared.requestPermission()
                        await NotificationManager.shared.scheduleWeeklySummary(container: dependencies.modelContainer)
                        await NotificationManager.shared.checkBudgetAlerts(container: dependencies.modelContainer)
                    }
                    BackgroundTaskManager.scheduleAppRefresh()
                }
        }
        .modelContainer(dependencies.modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhase(newPhase)
        }
    }

    /// Triggers telemetry uploads on app background and on foreground-after-idle.
    /// TelemetryLogger internally no-ops when the user has not opted in or when
    /// the last flush was less than 30 seconds ago, so it is safe to call often.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            let logger = dependencies.telemetryLogger
            Task { await logger.flushPending() }
        case .active:
            let idleGap = Date().timeIntervalSince(lastForegroundAt)
            lastForegroundAt = Date()
            if idleGap > HFConstants.Telemetry.foregroundIdleFlushSeconds {
                let logger = dependencies.telemetryLogger
                Task { await logger.flushPending() }
            }
        default:
            break
        }
    }
}
