import Foundation

/// Момент, когда будильник впервые «пошёл» (уведомление / AlarmKit). Чтобы при открытии приложения не начинать трек с нуля.
enum AlarmPlaybackAnchor {
    private static let key = "alarm.playbackAnchorWallClock"

    /// Сохранить самый ранний из известных моментов срабатывания.
    static func recordIfNeeded(_ date: Date) {
        let ts = date.timeIntervalSince1970
        if let existing = UserDefaults.standard.object(forKey: key) as? TimeInterval {
            if ts < existing {
                UserDefaults.standard.set(ts, forKey: key)
            }
        } else {
            UserDefaults.standard.set(ts, forKey: key)
        }
    }

    /// Сколько секунд прошло с якоря (для seek в плеере).
    static func elapsedSinceRecordedStart() -> TimeInterval? {
        guard let t = UserDefaults.standard.object(forKey: key) as? TimeInterval else { return nil }
        return max(0, Date().timeIntervalSince(Date(timeIntervalSince1970: t)))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
