import Foundation
@preconcurrency import UserNotifications

enum AlarmManagerError: Error {
    case notAuthorized
    case invalidTime
    case windowTooSmall
}

final class AlarmManager {
    private let center: UNUserNotificationCenter
    private let alarmIdentifier = "smart_alarm_wakeup"

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestNotificationPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    /// Schedules a one-time wake notification at a randomized moment within `windowMinutes` before `wakeTime`.
    @discardableResult
    func scheduleWakeUpNotification(wakeTime: Date, windowMinutes: Int = 30) async throws -> Date {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            throw AlarmManagerError.notAuthorized
        }

        let calendar = Calendar.current
        let now = Date()

        // Extract hour/minute from user-selected time.
        let hm = calendar.dateComponents([.hour, .minute], from: wakeTime)
        guard let hour = hm.hour, let minute = hm.minute else {
            throw AlarmManagerError.invalidTime
        }

        // Next occurrence of (hour, minute).
        var targetComponents = calendar.dateComponents([.year, .month, .day], from: now)
        targetComponents.hour = hour
        targetComponents.minute = minute
        targetComponents.second = 0

        var targetDate = calendar.date(from: targetComponents) ?? wakeTime
        if targetDate <= now {
            targetDate = calendar.date(byAdding: .day, value: 1, to: targetDate) ?? targetDate
        }

        let windowStart = targetDate.addingTimeInterval(-TimeInterval(windowMinutes) * 60)
        let earliestFireDate = max(windowStart, now.addingTimeInterval(1))
        guard earliestFireDate < targetDate else { throw AlarmManagerError.windowTooSmall }

        // Randomize inside the window for MVP.
        let totalSeconds = Int(targetDate.timeIntervalSince(earliestFireDate))
        let offsetSeconds = Int.random(in: 0...max(0, totalSeconds))
        let fireDate = earliestFireDate.addingTimeInterval(TimeInterval(offsetSeconds))

        let content = UNMutableNotificationContent()
        content.title = "Wake up"
        content.body = "Sleep mode is over."
        content.sound = .default

        let dateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)

        center.removePendingNotificationRequests(withIdentifiers: [alarmIdentifier])
        let request = UNNotificationRequest(identifier: alarmIdentifier, content: content, trigger: trigger)
        try await center.add(request)

        return fireDate
    }
}

