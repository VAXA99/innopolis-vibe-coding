#if canImport(MediaPlayer) && os(iOS)
import AVFoundation
import MediaPlayer

/// Один путь для превью и будильника — тот же `MPMusicPlayerController.applicationMusicPlayer`.
enum AlarmApplicationMusicPlayer {
    @MainActor
    static func configureSessionForAlarm() {
        try? AudioManager.configureSessionForAppleMusicAlarm()
    }

    /// Как превью, плюс `repeatMode` и стартовая позиция.
    /// Громкость трека из медиатеки задаёт система; программный crescendo для `MPMusicPlayerController` на iOS снят (`volume` недоступен).
    @MainActor
    static func playAlarmLoop(item: MPMediaItem, startTime: TimeInterval) {
        AlarmAppleMusicPlayback.ensureMPMusicPlayerNotificationsRegistered()
        configureSessionForAlarm()
        let p = MPMusicPlayerController.applicationMusicPlayer
        p.stop()
        p.setQueue(with: MPMediaItemCollection(items: [item]))
        let dur = item.playbackDuration
        if dur > 0.05 {
            p.currentPlaybackTime = min(max(0, startTime), dur - 0.01)
        } else {
            p.currentPlaybackTime = 0
        }
        p.repeatMode = .one
        p.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if p.playbackState != .playing {
                p.play()
            }
        }
    }
}
#endif
