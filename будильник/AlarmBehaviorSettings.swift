import Foundation

/// Snooze, crescendo, громкость будильника в приложении, дни недели (без HealthKit).
enum AlarmBehaviorSettings {
    private static let snoozeEnabledKey = "alarm.behavior.snoozeEnabled"
    private static let snoozeMinutesKey = "alarm.behavior.snoozeMinutes"
    private static let snoozeMaxKey = "alarm.behavior.snoozeMax"
    private static let weekdaysKey = "alarm.behavior.weekdays"
    private static let weekdayTimesKey = "alarm.behavior.weekdayTimes"
    private static let crescendoEnabledKey = "alarm.behavior.crescendoEnabled"
    private static let crescendoSecondsKey = "alarm.behavior.crescendoSeconds"
    private static let alarmVolumeKey = "alarm.behavior.alarmVolume"

    static var isSnoozeEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: snoozeEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: snoozeEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: snoozeEnabledKey) }
    }

    /// 5…20 минут.
    static var snoozeIntervalMinutes: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: snoozeMinutesKey)
            if v < 5 || v > 20 { return 9 }
            return v
        }
        set { UserDefaults.standard.set(min(20, max(5, newValue)), forKey: snoozeMinutesKey) }
    }

    /// 0 = без лимита.
    static var snoozeMaxCount: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: snoozeMaxKey)
            if v < 0 { return 5 }
            return min(20, v)
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: snoozeMaxKey) }
    }

    /// `Calendar` weekday: 1 = Sunday … 7 = Saturday. Пустое = все дни.
    static var weekdayMask: Set<Int> {
        get {
            guard let a = UserDefaults.standard.array(forKey: weekdaysKey) as? [Int] else {
                return Set(1 ... 7)
            }
            let s = Set(a.filter { (1 ... 7).contains($0) })
            return s.isEmpty ? Set(1 ... 7) : s
        }
        set {
            let sorted = Array(newValue).filter { (1 ... 7).contains($0) }.sorted()
            UserDefaults.standard.set(sorted.isEmpty ? Array(1 ... 7) : sorted, forKey: weekdaysKey)
        }
    }

    /// Индивидуальное время по дням недели (`weekday` 1...7) в минутах от начала суток.
    /// Если словарь пуст — используется общее время будильника (`AlarmViewModel.alarmTime`).
    static var weekdayTimesMinutes: [Int: Int] {
        get {
            guard let raw = UserDefaults.standard.dictionary(forKey: weekdayTimesKey) else { return [:] }
            var out: [Int: Int] = [:]
            for (k, v) in raw {
                guard let wd = Int(k), (1 ... 7).contains(wd) else { continue }
                if let minutes = v as? Int {
                    out[wd] = min(1439, max(0, minutes))
                } else if let num = v as? NSNumber {
                    out[wd] = min(1439, max(0, num.intValue))
                }
            }
            return out
        }
        set {
            var payload: [String: Int] = [:]
            for (wd, minutes) in newValue where (1 ... 7).contains(wd) {
                payload[String(wd)] = min(1439, max(0, minutes))
            }
            UserDefaults.standard.set(payload, forKey: weekdayTimesKey)
        }
    }

    /// По умолчанию включено: тихий старт и плавный подъём громкости (можно выключить в настройках).
    static var isCrescendoEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: crescendoEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: crescendoEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: crescendoEnabledKey) }
    }

    /// Длительность нарастания громкости (встроенный / файл), сек.
    static var crescendoRampSeconds: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: crescendoSecondsKey)
            if v < 10 || v > 120 { return 45 }
            return v
        }
        set { UserDefaults.standard.set(min(120, max(10, newValue)), forKey: crescendoSecondsKey) }
    }

    /// Множитель к базовой громкости рингтона в приложении (0.2…1.0).
    static var alarmVolumeMultiplier: Double {
        get {
            let v = UserDefaults.standard.double(forKey: alarmVolumeKey)
            if v < 0.15 || v > 1.01 { return 1.0 }
            return v
        }
        set { UserDefaults.standard.set(min(1.0, max(0.2, newValue)), forKey: alarmVolumeKey) }
    }
}

enum AlarmScheduling {
    /// Следующее срабатывание в выбранные дни недели после `now` (строго позже `now`).
    static func nextOccurrence(
        hour: Int,
        minute: Int,
        weekdays: Set<Int>,
        from now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let active: Set<Int> = weekdays.isEmpty ? Set(1 ... 7) : weekdays
        let startOfToday = calendar.startOfDay(for: now)
        for dayOffset in 0 ..< 14 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            var c = calendar.dateComponents([.year, .month, .day], from: dayStart)
            c.hour = hour
            c.minute = minute
            c.second = 0
            guard let candidate = calendar.date(from: c), candidate > now else { continue }
            let wd = calendar.component(.weekday, from: candidate)
            guard active.contains(wd) else { continue }
            return candidate
        }
        return now.addingTimeInterval(86_400)
    }
}
