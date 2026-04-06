//___FILEHEADER___

import SwiftUI
import UserNotifications
import UIKit
import MediaPlayer
import AVFoundation

extension Notification.Name {
    static let smartAlarmDidFire = Notification.Name("smartAlarmDidFire")
    /// `userInfo` key: `Date` срабатывания уведомления — чтобы не запускать будильник повторно при каждом входе в приложение.
    static let smartAlarmFireDateUserInfoKey = "smartAlarm.fireDate"
    static let sleepTimerDidEnd = Notification.Name("sleepTimerDidEnd")
    /// Lock screen / AirPods: user tapped Play — поднять сон-микс снова.
    static let sleepPlaybackRemotePlay = Notification.Name("sleepPlaybackRemotePlay")
    /// Пауза/стоп с экрана блокировки — остановить будильник и Apple Music.
    static let alarmRemoteStopRequested = Notification.Name("alarmRemoteStopRequested")
    /// Пользователь подтвердил пробуждение — снять отложенные «reminder» и флаг запланированного утра.
    static let userDismissedMorningAlarm = Notification.Name("userDismissedMorningAlarm")
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Lock screen / Control Center: treat sleep playback as remote-controllable media.
        application.beginReceivingRemoteControlEvents()
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.isEnabled = true
        rc.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: .sleepPlaybackRemotePlay, object: nil)
            return .success
        }
        rc.stopCommand.isEnabled = true
        rc.stopCommand.addTarget { _ in
            NotificationCenter.default.post(name: .alarmRemoteStopRequested, object: nil)
            return .success
        }
#if canImport(AlarmKit) && os(iOS)
        if #available(iOS 26.0, *) {
            AlarmKitAlarmLifecycleObserver.startIfNeeded()
        }
#endif
#if canImport(MediaPlayer) && os(iOS)
        if AlarmWakeSoundModeStorage.resolvedMode() == .appleMusic {
            Task {
                await AlarmAppleMusicPlayback.requestAuthorizationsIfNeeded()
            }
        }
#endif
        return true
    }

    func applicationDidEnterBackground(_: UIApplication) {
        // Сессия + маршрут на динамик до того, как observers увидят фон.
        try? AudioManager.configureSleepPlaybackSession()
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let id = notification.request.identifier
        if id == "smart_alarm_wakeup" || id == "smart_alarm_snooze" || id.hasPrefix("smart_alarm_wakeup_followup") {
            AlarmPlaybackAnchor.recordIfNeeded(notification.date)
            AlarmManager().clearWakeRemindersAfterInAppAlarmHandling()
            NotificationCenter.default.post(
                name: .smartAlarmDidFire,
                object: nil,
                userInfo: [Notification.Name.smartAlarmFireDateUserInfoKey: notification.date]
            )
        } else if id == "smart_alarm_sleep_timer_end" {
            NotificationCenter.default.post(name: .sleepTimerDidEnd, object: nil)
        }
        var options: UNNotificationPresentationOptions = [.sound, .badge]
        if #available(iOS 14.0, *) {
            options.formUnion([.banner, .list])
        } else {
            options.insert(.alert)
        }
        return options
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.identifier
        if id == "smart_alarm_wakeup" || id == "smart_alarm_snooze" || id.hasPrefix("smart_alarm_wakeup_followup") {
            AlarmPlaybackAnchor.recordIfNeeded(response.notification.date)
            AlarmManager().clearWakeRemindersAfterInAppAlarmHandling()
            NotificationCenter.default.post(
                name: .smartAlarmDidFire,
                object: nil,
                userInfo: [Notification.Name.smartAlarmFireDateUserInfoKey: response.notification.date]
            )
        } else if id == "smart_alarm_sleep_timer_end" {
            NotificationCenter.default.post(name: .sleepTimerDidEnd, object: nil)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
        }
    }
}

@main
struct SmartAlarmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
