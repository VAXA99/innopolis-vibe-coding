import Foundation
@preconcurrency import UserNotifications

/// Учитывает режим «встроенный / Apple Music / файл» при выборе звука уведомления.
enum AlarmWakeNotificationSound {
    static func resolved(for builtIn: AlarmSoundOption) -> UNNotificationSound {
        switch AlarmWakeSoundModeStorage.resolvedMode() {
        case .builtIn:
            return builtIn.notificationSound
        case .appleMusic:
            // Полный звук поднимаем в приложении (Apple Music / медиатека). Короткий тон уведомления — системный.
            return .default
        case .localFile:
            if let name = AlarmLocalFileStorage.notifySoundFileNameForUNNotification() {
                return UNNotificationSound(named: UNNotificationSoundName(name))
            }
            return builtIn.notificationSound
        }
    }
}

enum AlarmManagerError: Error {
    case notAuthorized
    case invalidTime
    case windowTooSmall
}

/// Группа встроенных рингтонов (папки `Ringtones/Mechanical` и `Ringtones/Musical`).
enum RingtoneCategory: String, CaseIterable, Identifiable {
    case mechanical
    case musical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mechanical: return "Mechanical"
        case .musical: return "Musical"
        }
    }
}

enum AlarmSoundOption: String, CaseIterable, Identifiable {
    /// Обычные / «механические» (3 шт.)
    case mechDigitalBuzzer
    case mechHighQuality
    case mechWindUp
    /// Музыкальные (5 шт.)
    case musCyberDay
    case musDreamscape
    case musLoFi
    case musOversimplified
    case musSoftPlucks

    var id: String { rawValue }

    static let mechanicalSounds: [AlarmSoundOption] = [.mechDigitalBuzzer, .mechHighQuality, .mechWindUp]
    static let musicalSounds: [AlarmSoundOption] = [
        .musCyberDay, .musDreamscape, .musLoFi, .musOversimplified, .musSoftPlucks
    ]

    /// Запасной звук при сбое Apple Music — только музыкальные рингтоны из бандла (mp3 в `Ringtones/Musical`).
    static func randomMusicalFallback() -> AlarmSoundOption {
        let safe: [AlarmSoundOption] = [.musDreamscape, .musSoftPlucks]
        return safe.randomElement() ?? .musSoftPlucks
    }

    static func sounds(for category: RingtoneCategory) -> [AlarmSoundOption] {
        switch category {
        case .mechanical: return mechanicalSounds
        case .musical: return musicalSounds
        }
    }

    var category: RingtoneCategory {
        Self.mechanicalSounds.contains(self) ? .mechanical : .musical
    }

    var title: String {
        switch self {
        case .mechDigitalBuzzer: return "Digital buzzer"
        case .mechHighQuality: return "High quality"
        case .mechWindUp: return "Mechanical wind-up"
        case .musCyberDay: return "Cyber day"
        case .musDreamscape: return "Dreamscape"
        case .musLoFi: return "Lo-fi"
        case .musOversimplified: return "Oversimplified"
        case .musSoftPlucks: return "Soft plucks"
        }
    }

    /// Короткий сигнал уведомления; полный рингтон — в приложении из `Ringtones/...` (mp3).
    var notificationSound: UNNotificationSound {
        .default
    }

    /// Полный рингтон в приложении (mp3 из бандла).
    func ringtoneFileURL() -> URL? {
        if let url = Bundle.main.url(forResource: mp3BaseName, withExtension: "mp3", subdirectory: mp3Subdirectory) {
            return url
        }
        // Some bundle layouts flatten resources; fallback to root.
        return Bundle.main.url(forResource: mp3BaseName, withExtension: "mp3")
    }

    /// mp3 для предпрослушивания и будильника в приложении (только встроенные рингтоны из бандла).
    func ringtonePlaybackURL() -> URL? {
        ringtoneFileURL()
    }

    private var mp3Subdirectory: String {
        switch category {
        case .mechanical: return "Ringtones/Mechanical"
        case .musical: return "Ringtones/Musical"
        }
    }

    private var mp3BaseName: String {
        switch self {
        case .mechDigitalBuzzer:
            return "flutie8211-digital-alarm-clock-buzzer-458027"
        case .mechHighQuality:
            return "freesound_community-alarm-clock-high-quality-20276"
        case .mechWindUp:
            return "patolenin-natural-sound-of-a-mechanical-wind-up-clock-with-alarm-435080"
        case .musCyberDay:
            return "lesiakower-cyber-day-alarm-clock-418781"
        case .musDreamscape:
            return "lesiakower-dreamscape-alarm-clock-117680"
        case .musLoFi:
            return "lesiakower-lo-fi-alarm-clock-243766"
        case .musOversimplified:
            return "lesiakower-oversimplified-alarm-clock-113180"
        case .musSoftPlucks:
            return "lesiakower-soft-plucks-alarm-clock-120696"
        }
    }

    /// Старые ключи из UserDefaults.
    static func migrated(from raw: String) -> AlarmSoundOption? {
        if let v = AlarmSoundOption(rawValue: raw) { return v }
        switch raw {
        case "pulse", "default": return .mechDigitalBuzzer
        case "beacon", "ringtone": return .mechHighQuality
        case "siren", "critical": return .mechWindUp
        default: return nil
        }
    }
}

/// Источник звука будильника: встроенный рингтон, Apple Music или локальный файл из «Файлы».
enum AlarmWakeSoundMode: String, CaseIterable, Identifiable {
    case builtIn
    case appleMusic
    case localFile

    var id: String { rawValue }
}

enum AlarmWakeSoundModeStorage {
    private static let key = "alarm.wakeSoundMode"

    /// Читает сохранённый режим; при первом запуске мигрирует со старой логики.
    static func resolvedMode() -> AlarmWakeSoundMode {
        if let raw = UserDefaults.standard.string(forKey: key),
           let mode = AlarmWakeSoundMode(rawValue: raw) {
            return mode
        }
        // Сначала файл из «Файлы» — иначе старая запись про Apple Music перебивала режим «файл».
        if AlarmLocalFileStorage.hasImportedFile() {
            UserDefaults.standard.set(AlarmWakeSoundMode.localFile.rawValue, forKey: key)
            return .localFile
        }
        if AlarmMelodyStorage.load() != nil {
            UserDefaults.standard.set(AlarmWakeSoundMode.appleMusic.rawValue, forKey: key)
            return .appleMusic
        }
        UserDefaults.standard.set(AlarmWakeSoundMode.builtIn.rawValue, forKey: key)
        return .builtIn
    }

    static func set(_ mode: AlarmWakeSoundMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }
}

final class AlarmManager {
    private let center: UNUserNotificationCenter
    private let alarmIdentifier = "smart_alarm_wakeup"
    private let alarmFollowupPrefix = "smart_alarm_wakeup_followup"
    private let sleepTimerIdentifier = "smart_alarm_sleep_timer_end"
    /// Max follow-ups we ever scheduled (cleanup only).
    private static let maxLegacyFollowups = 5

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Removes morning wake request(s), legacy follow-ups, and delivered copies — use when user clears the alarm or after handling wake.
    func cancelScheduledMorningAlarm() {
#if canImport(AlarmKit) && os(iOS)
        if #available(iOS 26.0, *) {
            AlarmKitWakeScheduler.cancelScheduledWake()
        }
#endif
        var ids = [alarmIdentifier]
        ids += (1...Self.maxLegacyFollowups).map { "\(alarmFollowupPrefix)_\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func cancelSleepTimerNotification() {
        center.removePendingNotificationRequests(withIdentifiers: [sleepTimerIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [sleepTimerIdentifier])
    }

    /// Следующее время срабатывания утреннего `smart_alarm_wakeup` (если запланировано).
    /// Нужно режиму сна с фоновым аудио: пока процесс жив, можно поднять Apple Music/полный звук в момент `fireDate`, без ожидания `willPresent` (он не вызывается при заблокированном экране).
    func nextScheduledMainWakeFireDate() async -> Date? {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                guard let req = requests.first(where: { $0.identifier == self.alarmIdentifier }),
                      let cal = req.trigger as? UNCalendarNotificationTrigger else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: cal.nextTriggerDate())
            }
        }
    }

    func requestNotificationPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            return false
        }
    }

    /// Schedules a one-time wake notification.
    /// - If `windowMinutes` is 0, fires exactly at `wakeTime` (next occurrence).
    /// - If `windowMinutes` > 0, fires randomly in the wake window.
    @discardableResult
    func scheduleWakeUpNotification(
        wakeTime: Date,
        windowMinutes: Int = 30,
        sound: AlarmSoundOption = .mechDigitalBuzzer,
        followupCount: Int = 0,
        followupIntervalMinutes: Int = 2
    ) async throws -> Date {
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

        let fireDate: Date
        if windowMinutes <= 0 {
            fireDate = max(targetDate, now.addingTimeInterval(1))
        } else {
            let windowStart = targetDate.addingTimeInterval(-TimeInterval(windowMinutes) * 60)
            let earliestFireDate = max(windowStart, now.addingTimeInterval(1))
            if earliestFireDate >= targetDate {
                fireDate = max(targetDate, now.addingTimeInterval(1))
            } else {
                let totalSeconds = Int(targetDate.timeIntervalSince(earliestFireDate))
                let offsetSeconds = Int.random(in: 0...max(0, totalSeconds))
                fireDate = earliestFireDate.addingTimeInterval(TimeInterval(offsetSeconds))
            }
        }

        var idsToRemove = [alarmIdentifier]
        idsToRemove += (1...Self.maxLegacyFollowups).map { "\(alarmFollowupPrefix)_\($0)" }
        center.removePendingNotificationRequests(withIdentifiers: idsToRemove)
        center.removeDeliveredNotifications(withIdentifiers: idsToRemove)

#if canImport(AlarmKit) && os(iOS)
        // AlarmKit не ставит UNNotification — при убитом процессе нечего поймать в reconcile.
        // Для «Файлы» и Apple Music нужен гарантированный локальный запрос + полный звук в приложении.
        if #available(iOS 26.0, *) {
            if AlarmWakeSoundModeStorage.resolvedMode() == .builtIn {
                do {
                    if try await AlarmKitWakeScheduler.scheduleMainWake(fireDate: fireDate, sound: sound) {
                        return fireDate
                    }
                } catch {
                    // Fallback: локальное уведомление ниже.
                }
            }
        }
#endif

        let content = UNMutableNotificationContent()
        content.title = "Wake up"
        content.body = "Time to wake up."
        content.sound = AlarmWakeNotificationSound.resolved(for: sound)
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let dateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)

        let request = UNNotificationRequest(identifier: alarmIdentifier, content: content, trigger: trigger)
        try await center.add(request)

        let safeInterval = max(1, followupIntervalMinutes)
        if followupCount > 0 {
            for idx in 1...followupCount {
                let followupDate = fireDate.addingTimeInterval(TimeInterval(idx * safeInterval * 60))
                let followupComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: followupDate)
                let followupTrigger = UNCalendarNotificationTrigger(dateMatching: followupComponents, repeats: false)
                let followupContent = UNMutableNotificationContent()
                followupContent.title = "Wake up"
                followupContent.body = "Alarm reminder \(idx)"
                followupContent.sound = AlarmWakeNotificationSound.resolved(for: sound)
                if #available(iOS 15.0, *) {
                    followupContent.interruptionLevel = .timeSensitive
                }

                let followupRequest = UNNotificationRequest(
                    identifier: "\(alarmFollowupPrefix)_\(idx)",
                    content: followupContent,
                    trigger: followupTrigger
                )
                try await center.add(followupRequest)
            }
        }

        return fireDate
    }

    /// Надёжное уведомление по окончании таймера сна (в т.ч. симулятор). Использует интервал, а не календарь.
    func scheduleSleepTimerEndNotification(
        secondsFromNow: Int,
        sound: AlarmSoundOption
    ) async throws {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        default:
            throw AlarmManagerError.notAuthorized
        }

        let sec = max(5, secondsFromNow)
        center.removePendingNotificationRequests(withIdentifiers: [sleepTimerIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [sleepTimerIdentifier])

        let content = UNMutableNotificationContent()
        content.title = "Wake up"
        content.body = "Sleep timer finished."
        content.sound = AlarmWakeNotificationSound.resolved(for: sound)
        if #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(sec), repeats: false)
        let request = UNNotificationRequest(identifier: sleepTimerIdentifier, content: content, trigger: trigger)
        try await center.add(request)
    }
}

