import SwiftUI
import SwiftData
import HFData

@main
struct HyperFinApp: App {
    let dependencies: AppDependencies

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
    }
}
