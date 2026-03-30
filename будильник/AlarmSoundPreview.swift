import AVFoundation
import Foundation

/// Предпросмотр выбранного mp3 из бандла (короткий фрагмент).
enum AlarmSoundPreview {
    private static var player: AVAudioPlayer?
    private static var stopWorkItem: DispatchWorkItem?

    /// Предпросмотр файла из «Файлы» (короткий фрагмент).
    static func playFile(at url: URL, previewDuration: TimeInterval = 5.0) {
        player?.stop()
        player = nil
        stopWorkItem?.cancel()
        stopWorkItem = nil
        let run = {
            do {
                #if os(iOS)
                do {
                    try AudioManager.configureAlarmPreviewSession()
                } catch {
                    try? AudioManager.configureSleepPlaybackSession()
                }
                AudioManager.routeAlarmPreviewToLoudSpeakerIfPossible()
                #endif
                let p = try AVAudioPlayer(contentsOf: url)
                p.volume = 0.95
                p.numberOfLoops = -1
                p.prepareToPlay()
                let ok = p.play()
                guard ok else {
                    #if os(iOS)
                    AudioManager.resetAlarmPreviewOutputOverride()
                    #endif
                    return
                }
                player = p
                let duration = max(1.0, previewDuration)
                let work = DispatchWorkItem {
                    player?.stop()
                    player = nil
                    stopWorkItem = nil
                    #if os(iOS)
                    AudioManager.resetAlarmPreviewOutputOverride()
                    #endif
                }
                stopWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
            } catch {
                #if os(iOS)
                AudioManager.resetAlarmPreviewOutputOverride()
                #endif
                player = nil
                stopWorkItem = nil
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    static func play(_ option: AlarmSoundOption, previewDuration: TimeInterval = 5.0) {
        player?.stop()
        player = nil
        stopWorkItem?.cancel()
        stopWorkItem = nil
        guard let url = option.ringtonePlaybackURL() else { return }
        let run = {
            do {
                #if os(iOS)
                do {
                    try AudioManager.configureAlarmPreviewSession()
                } catch {
                    try? AudioManager.configureSleepPlaybackSession()
                }
                AudioManager.routeAlarmPreviewToLoudSpeakerIfPossible()
                #endif
                let p = try AVAudioPlayer(contentsOf: url)
                p.volume = option.category == .musical ? 0.92 : 1.0
                p.numberOfLoops = -1
                p.prepareToPlay()
                let ok = p.play()
                guard ok else {
                    #if os(iOS)
                    AudioManager.resetAlarmPreviewOutputOverride()
                    #endif
                    return
                }
                player = p
                let duration = max(1.0, previewDuration)
                let work = DispatchWorkItem {
                    player?.stop()
                    player = nil
                    stopWorkItem = nil
                    #if os(iOS)
                    AudioManager.resetAlarmPreviewOutputOverride()
                    #endif
                }
                stopWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
            } catch {
                #if os(iOS)
                AudioManager.resetAlarmPreviewOutputOverride()
                #endif
                player = nil
                stopWorkItem = nil
            }
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    static func stop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        player?.stop()
        player = nil
        #if os(iOS)
        AudioManager.resetAlarmPreviewOutputOverride()
        #endif
    }
}
