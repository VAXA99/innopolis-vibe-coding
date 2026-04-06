#if canImport(AlarmKit) && os(iOS)
import AlarmKit
import Foundation

/// Когда AlarmKit переводит будильник в `alerting`, сначала глушим системный слой AlarmKit (иначе одновременно и «цифровой» системный звук, и наш плеер).
/// Затем тот же путь, что и от уведомления — встроенный рингтон или Apple Music через приложение.
@available(iOS 26.0, *)
enum AlarmKitAlarmLifecycleObserver {
    private static var listeningTask: Task<Void, Never>?
    private static var lastPostedAlerting = false

    static func startIfNeeded() {
        listeningTask?.cancel()
        lastPostedAlerting = false
        listeningTask = Task {
            for await alarms in AlarmKit.AlarmManager.shared.alarmUpdates {
                await MainActor.run {
                    guard let wanted = AlarmKitWakeScheduler.scheduledAlarmId else {
                        lastPostedAlerting = false
                        return
                    }
                    let mine = alarms.first(where: { $0.id == wanted })
                    let nowAlerting = mine?.state == .alerting
                    if nowAlerting {
                        if !lastPostedAlerting {
                            lastPostedAlerting = true
                            try? AlarmKit.AlarmManager.shared.stop(id: wanted)
                            NotificationCenter.default.post(
                                name: .smartAlarmDidFire,
                                object: nil,
                                userInfo: [Notification.Name.smartAlarmFireDateUserInfoKey: Date()]
                            )
                        }
                    } else {
                        lastPostedAlerting = false
                    }
                }
            }
        }
    }
}
#endif
