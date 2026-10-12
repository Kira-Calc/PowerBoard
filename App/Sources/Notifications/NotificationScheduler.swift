import ElectricityCore
import Foundation
import UserNotifications

/// Sends the daily and weekly summaries and the daily threshold alert (SPEC 9.5).
/// Checks once a minute while the app runs; each notification is sent at most once per period.
@MainActor
final class NotificationScheduler {
    private enum Key {
        static let lastDaily = "notifications.lastDaily"
        static let lastWeekly = "notifications.lastWeekly"
        static let lastThreshold = "notifications.lastThreshold"
    }

    private let model: AppModel
    private let settings: AppSettings
    private var timer: Task<Void, Never>?

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func start() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(now: Date())
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        timer?.cancel()
    }

    private func check(now: Date) async {
        guard settings.dailyReportEnabled || settings.weeklyReportEnabled || settings.thresholdEnabled,
              let today = model.snapshot?.today
        else { return }
        let calendar = Calendar.current
        let defaults = settings.defaults
        let dayKey = today.date
        let minutesNow = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let reportDue = minutesNow >= settings.dailyReportMinutes

        if settings.thresholdEnabled, today.energyWh.mid >= settings.thresholdWh,
           defaults.string(forKey: Key.lastThreshold) != dayKey {
            defaults.set(dayKey, forKey: Key.lastThreshold)
            send(
                title: String(localized: "notification.threshold.title"),
                body: String(format: String(localized: "notification.threshold.body"),
                             settings.formatEnergy(settings.thresholdWh).text, settings.formatEnergy(today.energyWh.mid).text)
            )
        }

        if settings.dailyReportEnabled, reportDue, defaults.string(forKey: Key.lastDaily) != dayKey {
            defaults.set(dayKey, forKey: Key.lastDaily)
            send(
                title: String(localized: "notification.daily.title"),
                body: String(format: String(localized: "notification.daily.body"),
                             settings.formatEnergy(today.energyWh.mid).text, ValueFormatting.carbon(grams: today.co2G).text, Units.co2e)
            )
        }

        // Weekly summary on the first day of the week, covering the previous week.
        if settings.weeklyReportEnabled, reportDue,
           calendar.component(.weekday, from: now) == calendar.firstWeekday,
           defaults.string(forKey: Key.lastWeekly) != dayKey,
           let store = model.store {
            defaults.set(dayKey, forKey: Key.lastWeekly)
            let thisWeek = LocalPeriod.week.interval(containing: now, calendar: calendar)
            let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeek.start) ?? thisWeek.start
            let totals = await Task.detached { try? store.totals(from: lastWeekStart, to: thisWeek.start) }.value
            if let totals {
                send(
                    title: String(localized: "notification.weekly.title"),
                    body: String(format: String(localized: "notification.weekly.body"),
                                  settings.formatEnergy(totals.energyWh.mid).text, ValueFormatting.carbon(grams: totals.co2GramsMid).text, Units.co2e)
                )
            }
        }
    }

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
