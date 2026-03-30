import AVFoundation
import Foundation

/// Локальный файл из «Файлы»: полная копия для будильника в приложении + короткий M4A для `UNNotificationSound` (экран выключен).
enum AlarmLocalFileStorage {
    private static let fullFileKey = "alarm.localFile.savedFileName"
    private static let displayNameKey = "alarm.localFile.displayName"

    private static let destBaseName = "alarm_user_wake_custom"
    /// Отдельный AAC/m4a до 30 с — так iOS реально играет звук на экране блокировки (MP3 там часто даёт системный дефолт / «сирену»).
    private static let notifyExportFileName = "alarm_user_wake_notify.m4a"
    private static let maxNotifySeconds: Double = 30

    static var soundsDirectoryURL: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("Sounds", isDirectory: true)
    }

    /// Полный файл для `AlarmRingPlayer` (mp3/m4a/…).
    static func playbackURL() -> URL? {
        guard let name = UserDefaults.standard.string(forKey: fullFileKey), !name.isEmpty else { return nil }
        let url = soundsDirectoryURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Имя для `UNNotificationSound(named:)` — только m4a из экспорта.
    static func notifySoundFileNameForUNNotification() -> String? {
        let url = soundsDirectoryURL.appendingPathComponent(notifyExportFileName)
        return FileManager.default.fileExists(atPath: url.path) ? notifyExportFileName : nil
    }

    static func displayName() -> String? {
        UserDefaults.standard.string(forKey: displayNameKey)
    }

    static func hasImportedFile() -> Bool { playbackURL() != nil }

    /// Готов ли короткий M4A для `UNNotificationSound` (экран выключен).
    static func hasLockScreenNotifyClipReady() -> Bool {
        notifySoundFileNameForUNNotification() != nil
    }

    /// Гарантирует наличие m4a для уведомления: несколько попыток экспорта (длина клипа). Если файла ещё нет — `true` (нечего готовить).
    static func prepareLockScreenNotifyClip() async -> Bool {
        guard let fullURL = playbackURL() else { return true }
        let notifyURL = soundsDirectoryURL.appendingPathComponent(notifyExportFileName)
        if FileManager.default.fileExists(atPath: notifyURL.path) { return true }

        let caps: [Double] = [maxNotifySeconds, 20, 15, 10]
        for cap in caps {
            try? FileManager.default.removeItem(at: notifyURL)
            do {
                try await exportNotifyM4A(from: fullURL, outputURL: notifyURL, maxSeconds: cap)
                return FileManager.default.fileExists(atPath: notifyURL.path)
            } catch {
                continue
            }
        }
        return false
    }

    /// Копирует оригинал и строит короткий M4A для уведомления (блокировка экрана).
    static func importSecurityScopedFile(from sourceURL: URL) async throws {
        let ext = sourceURL.pathExtension.lowercased()
        let allowed = Set(["mp3", "m4a", "aac", "wav", "caf", "aiff", "aif"])
        guard allowed.contains(ext) else {
            throw AlarmLocalFileImportError.unsupportedFormat
        }

        try FileManager.default.createDirectory(at: soundsDirectoryURL, withIntermediateDirectories: true)

        let destName = "\(destBaseName).\(ext)"
        let destURL = soundsDirectoryURL.appendingPathComponent(destName)

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        UserDefaults.standard.set(destName, forKey: fullFileKey)
        UserDefaults.standard.set(sourceURL.lastPathComponent, forKey: displayNameKey)

        let notifyURL = soundsDirectoryURL.appendingPathComponent(notifyExportFileName)
        if FileManager.default.fileExists(atPath: notifyURL.path) {
            try? FileManager.default.removeItem(at: notifyURL)
        }

        do {
            try await exportNotifyM4A(from: destURL, outputURL: notifyURL, maxSeconds: maxNotifySeconds)
        } catch {
            // Полный файл уже сохранён — prepareLockScreenNotifyClip при Set Alarm.
        }
    }

    /// Перед планированием уведомления (дублирует логику prepare, но лёгкая если файл уже есть).
    static func ensureNotifyExportIfNeeded() async {
        _ = await prepareLockScreenNotifyClip()
    }

    static func clear() {
        if let name = UserDefaults.standard.string(forKey: fullFileKey) {
            try? FileManager.default.removeItem(at: soundsDirectoryURL.appendingPathComponent(name))
        }
        let notifyURL = soundsDirectoryURL.appendingPathComponent(notifyExportFileName)
        try? FileManager.default.removeItem(at: notifyURL)
        UserDefaults.standard.removeObject(forKey: fullFileKey)
        UserDefaults.standard.removeObject(forKey: displayNameKey)
    }

    private static func exportNotifyM4A(from inputURL: URL, outputURL: URL, maxSeconds: Double) async throws {
        let asset = AVURLAsset(url: inputURL)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            throw AlarmLocalFileImportError.exportFailed
        }
        var seconds = CMTimeGetSeconds(duration)
        if !seconds.isFinite || seconds <= 0 {
            seconds = maxSeconds
        }
        let cap = min(maxNotifySeconds, maxSeconds)
        let exportDuration = min(max(0.5, seconds), cap)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AlarmLocalFileImportError.exportFailed
        }
        session.outputURL = outputURL
        session.outputFileType = AVFileType.m4a
        session.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: exportDuration, preferredTimescale: 600)
        )

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                cont.resume()
            }
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AlarmLocalFileImportError.exportFailed
        }
    }
}

enum AlarmLocalFileImportError: LocalizedError {
    case unsupportedFormat
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Use MP3, M4A, WAV, or CAF."
        case .exportFailed:
            return "Could not prepare sound for lock screen. Try another file or format."
        }
    }
}
