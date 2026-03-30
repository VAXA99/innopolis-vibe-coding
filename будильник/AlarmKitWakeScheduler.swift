#if canImport(AlarmKit) && os(iOS)
import ActivityKit
import AlarmKit
import Foundation
import SwiftUI

/// iOS 26+: системный будильник через AlarmKit (как в приложении «Часы») — работает при заблокированном экране.
/// Системный тон будильника; полный рингтон из бандла — в приложении при `.alerting` (см. `AlarmKitAlarmLifecycleObserver`).
@available(iOS 26.0, *)
struct SmartAlarmKitMetadata: AlarmKit.AlarmMetadata {}

@available(iOS 26.0, *)
enum AlarmKitWakeScheduler {
    static let storedAlarmUUIDKey = "alarmkit.mainWake.uuid"

    /// Отменяет ранее запланированный AlarmKit-будильник (если был).
    static func cancelScheduledWake() {
        guard let raw = UserDefaults.standard.string(forKey: storedAlarmUUIDKey),
              let id = UUID(uuidString: raw) else { return }
        try? AlarmKit.AlarmManager.shared.cancel(id: id)
        UserDefaults.standard.removeObject(forKey: storedAlarmUUIDKey)
    }

    /// Планирует одноразовый будильник на точное время. При успехе локальное уведомление `smart_alarm_wakeup` не нужно.
    static func scheduleMainWake(fireDate: Date, sound _: AlarmSoundOption) async throws -> Bool {
        let kit = AlarmKit.AlarmManager.shared
        switch kit.authorizationState {
        case .notDetermined:
            let state = try await kit.requestAuthorization()
            guard state == .authorized else { return false }
        case .authorized:
            break
        case .denied:
            return false
        @unknown default:
            return false
        }

        cancelScheduledWake()

        let alert = AlarmKit.AlarmPresentation.Alert(
            title: LocalizedStringResource("Wake up"),
            secondaryButton: nil,
            secondaryButtonBehavior: nil
        )
        let attributes = AlarmKit.AlarmAttributes<SmartAlarmKitMetadata>(
            presentation: AlarmKit.AlarmPresentation(alert: alert),
            metadata: nil,
            tintColor: .orange
        )

        let schedule = AlarmKit.Alarm.Schedule.fixed(fireDate)
        let configuration = AlarmKit.AlarmManager.AlarmConfiguration<SmartAlarmKitMetadata>.alarm(
            schedule: schedule,
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .default
        )

        let id = UUID()
        _ = try await kit.schedule(id: id, configuration: configuration)
        UserDefaults.standard.set(id.uuidString, forKey: storedAlarmUUIDKey)
        return true
    }

    static var scheduledAlarmId: UUID? {
        guard let raw = UserDefaults.standard.string(forKey: storedAlarmUUIDKey) else { return nil }
        return UUID(uuidString: raw)
    }
}
#endif
