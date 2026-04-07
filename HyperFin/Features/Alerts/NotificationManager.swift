import Foundation
import UserNotifications
import SwiftData
import HFData
import HFDomain
import HFShared

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            HFLogger.general.info("Notification permission: \(granted)")
            return granted
        } catch {
            HFLogger.general.error("Notification permission error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Budget Threshold Alerts

    func checkBudgetAlerts(container: ModelContainer) async {
        let context = container.mainContext
        let monthStart = Date().startOfMonth

        guard let budgets = try? context.fetch(FetchDescriptor<SDBudget>()),
              let budget = budgets.first(where: { Calendar.current.isDate($0.month, equalTo: monthStart, toGranularity: .month) })
        else { return }

        let categories = (try? context.fetch(FetchDescriptor<SDCategory>())) ?? []
        let transactions = (try? context.fetch(FetchDescriptor<SDTransaction>())) ?? []
        let alertConfigs = (try? context.fetch(FetchDescriptor<SDAlertConfig>())) ?? []

        let thresholdEnabled = alertConfigs.first { $0.alertTypeRaw == AlertType.budgetThreshold.rawValue }?.isEnabled ?? true
        let exceededEnabled = alertConfigs.first { $0.alertTypeRaw == AlertType.budgetExceeded.rawValue }?.isEnabled ?? true

        for line in budget.lines {
            let spent = transactions
                .filter { $0.categoryId == line.categoryId && $0.date >= monthStart && $0.amount > 0 }
                .reduce(Decimal.zero) { $0 + $1.amount }

            let percent = line.allocatedAmount > 0
                ? Double(truncating: (spent / line.allocatedAmount) as NSDecimalNumber)
                : 0

            let catName = categories.first { $0.id == line.categoryId }?.name ?? "Unknown"

            if percent >= 1.0 && exceededEnabled {
                await sendNotification(
                    id: "budget-exceeded-\(line.categoryId.uuidString)",
                    title: "Budget Exceeded",
                    body: "\(catName) spending (\(spent.currencyFormatted)) has exceeded your \(line.allocatedAmount.currencyFormatted) budget.",
                    category: "BUDGET_ALERT"
                )
            } else if percent >= 0.8 && thresholdEnabled {
                await sendNotification(
                    id: "budget-threshold-\(line.categoryId.uuidString)",
                    title: "Budget Warning",
                    body: "\(catName) is at \(Int(percent * 100))% of your \(line.allocatedAmount.currencyFormatted) budget.",
                    category: "BUDGET_ALERT"
                )
            }
        }
    }

    // MARK: - Unusual Transaction Alert

    func checkUnusualTransaction(_ transaction: SDTransaction, container: ModelContainer) async {
        let context = container.mainContext
        let alertConfigs = (try? context.fetch(FetchDescriptor<SDAlertConfig>())) ?? []
        let enabled = alertConfigs.first { $0.alertTypeRaw == AlertType.unusualTransaction.rawValue }?.isEnabled ?? true

        guard enabled, transaction.amount > 0 else { return }

        // Compare against average for this category
        let ninetyDaysAgo = Date().daysAgo(90)
        let allTxns = (try? context.fetch(FetchDescriptor<SDTransaction>())) ?? []
        let similarTxns = allTxns.filter {
            $0.categoryId == transaction.categoryId &&
            $0.date >= ninetyDaysAgo &&
            $0.amount > 0 &&
            $0.id != transaction.id
        }

        guard similarTxns.count >= 5 else { return }

        let avg = similarTxns.reduce(Decimal.zero) { $0 + $1.amount } / Decimal(similarTxns.count)

        if transaction.amount > avg * 2 {
            let merchant = transaction.merchantName ?? "Unknown"
            await sendNotification(
                id: "unusual-\(transaction.id.uuidString)",
                title: "Unusual Transaction",
                body: "\(merchant) charged \(transaction.amount.currencyFormatted) — this is higher than your usual spending in this category.",
                category: "UNUSUAL_TRANSACTION"
            )
        }
    }

    // MARK: - Weekly Summary

    func scheduleWeeklySummary(container: ModelContainer) async {
        let context = container.mainContext
        let alertConfigs = (try? context.fetch(FetchDescriptor<SDAlertConfig>())) ?? []
        let config = alertConfigs.first { $0.alertTypeRaw == AlertType.weeklySummary.rawValue }

        guard config?.isEnabled != false else { return }

        let day = config?.preferredDay ?? 2 // Default: Monday
        let hour = config?.preferredHour ?? 9

        // Remove existing weekly summary
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["weekly-summary"])

        let content = UNMutableNotificationContent()
        content.title = "Weekly Spending Summary"
        content.body = "Tap to see how your spending tracked against your budget this week."
        content.sound = .default
        content.categoryIdentifier = "WEEKLY_SUMMARY"

        var dateComponents = DateComponents()
        dateComponents.weekday = day
        dateComponents.hour = hour
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: "weekly-summary", content: content, trigger: trigger)

        try? await UNUserNotificationCenter.current().add(request)
        HFLogger.general.info("Weekly summary scheduled for weekday \(day) at \(hour):00")
    }

    // MARK: - Helpers

    private func sendNotification(id: String, title: String, body: String, category: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            HFLogger.general.info("Notification sent: \(title)")
        } catch {
            HFLogger.general.error("Failed to send notification: \(error.localizedDescription)")
        }
    }
}
