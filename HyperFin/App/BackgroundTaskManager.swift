import Foundation
import BackgroundTasks
import SwiftData
import HFShared

enum BackgroundTaskManager {
    static let refreshTaskId = "com.hyperfin.app.refresh"

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshTaskId,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handleAppRefresh(task: task)
        }
        HFLogger.general.info("Background refresh task registered")
    }

    static func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600) // 4 hours
        do {
            try BGTaskScheduler.shared.submit(request)
            HFLogger.general.info("Background refresh scheduled for ~4 hours from now")
        } catch {
            HFLogger.general.error("Could not schedule background refresh: \(error.localizedDescription)")
        }
    }

    private static func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleAppRefresh() // Reschedule for next interval

        let operationTask = Task { @MainActor in
            // The container will be retrieved from the app's shared instance
            // For now, budget checks happen when app opens
            HFLogger.general.info("Background refresh executing")
        }

        task.expirationHandler = {
            operationTask.cancel()
        }

        nonisolated(unsafe) let bgTask = task
        Task {
            await operationTask.value
            bgTask.setTaskCompleted(success: true)
        }
    }
}
