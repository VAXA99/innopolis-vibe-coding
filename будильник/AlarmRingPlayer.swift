import AVFoundation
import Combine
import Foundation
#if canImport(UIKit) && os(iOS)
import UIKit
#endif
#if canImport(MediaPlayer) && os(iOS)
import MediaPlayer
#endif
#if canImport(MusicKit) && os(iOS)
import MusicKit
#endif
/// Full-volume looping alarm inside the app (notifications alone cannot match the Clock app).
/// Для Apple Music: `applicationMusicPlayer` + Now Playing на экране блокировки / в центре управления (как у Sleepzy).
@MainActor
final class AlarmRingPlayer {
    private var player: AVAudioPlayer?
    /// Запасной путь для MP3/M4A, если `AVAudioPlayer` откажется (редко, но без этого падали в встроенный рингтон).
    private var fileLoopPlayer: AVPlayer?
    private var fileLoopEndObserver: NSObjectProtocol?
    private var vibrateTimer: Timer?
#if canImport(UIKit) && os(iOS)
    private var alarmHaptics: UIImpactFeedbackGenerator?
#endif
#if canImport(MediaPlayer) && os(iOS)
    private let musicPlayer = MPMusicPlayerController.applicationMusicPlayer
    private var publishedAppleMusicNowPlaying = false
#endif
#if canImport(MusicKit) && os(iOS)
    /// Когда играет `ApplicationMusicPlayer` (каталог по Store ID) — не смешивать с `MPMusicPlayerController` в reassert/stop.
    private var usesMusicKitPlayback = false
#endif
    /// `usePlaybackAnchor`: если будильник уже играл с экрана блокировки — продолжить с той же позиции (см. `AlarmPlaybackAnchor`).
    func start(option: AlarmSoundOption, usePlaybackAnchor: Bool = true) {
        let elapsed = usePlaybackAnchor ? (AlarmPlaybackAnchor.elapsedSinceRecordedStart() ?? 0) : 0
        stop()
        if AlarmWakeSoundModeStorage.resolvedMode() == .appleMusic {
            Task { @MainActor in
                await self.startAppleMusicAlarm(option: option, elapsed: elapsed)
            }
            return
        }
        // Сначала файл — иначе устаревшая логика Apple Music или порядок проверок мешали MP3.
        if startLocalFilePlayback(option: option, elapsed: elapsed) {
            startAlarmVibrationLoop()
            return
        }

        guard let url = option.ringtonePlaybackURL() else {
            startBundledFallbackAlarm(option: option, elapsed: elapsed)
            return
        }
        do {
            try configureSession()
            #if os(iOS)
            AudioManager.routeAlarmPlaybackToSpeakerIfPossible()
            #endif
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = option.category == .musical ? 0.92 : 1.0
            p.prepareToPlay()
            p.currentTime = applyPlaybackOffset(elapsed: elapsed, duration: p.duration)
            p.play()
            player = p
            startAlarmVibrationLoop()
        } catch {
            startBundledFallbackAlarm(option: option, elapsed: elapsed)
        }
    }

    func stop() {
        vibrateTimer?.invalidate()
        vibrateTimer = nil
#if canImport(UIKit) && os(iOS)
        alarmHaptics = nil
#endif
        if let o = fileLoopEndObserver {
            NotificationCenter.default.removeObserver(o)
            fileLoopEndObserver = nil
        }
        fileLoopPlayer?.pause()
        fileLoopPlayer = nil
        player?.stop()
        player = nil
        #if os(iOS)
        AudioManager.resetAlarmPreviewOutputOverride()
        #endif
#if canImport(MusicKit) && os(iOS)
        if usesMusicKitPlayback {
            Task { @MainActor in
                ApplicationMusicPlayer.shared.pause()
            }
            usesMusicKitPlayback = false
        }
#endif
#if canImport(MediaPlayer) && os(iOS)
        musicPlayer.stop()
        if publishedAppleMusicNowPlaying {
            clearAppleMusicNowPlayingInfo()
            publishedAppleMusicNowPlaying = false
        }
#endif
    }

    /// Фон / блокировка: сессия и плеер могут остановиться — поднять без полного `start()` (не сбрасывать трек с начала).
    func reassertAlarmPlaybackIfNeeded() {
        #if os(iOS)
        if AlarmWakeSoundModeStorage.resolvedMode() == .appleMusic {
            try? AudioManager.configureSessionForAppleMusicAlarm()
        } else {
            try? AudioManager.configureSleepPlaybackSession()
        }
        #endif
        if let p = player, !p.isPlaying {
            p.play()
        }
        if let pl = fileLoopPlayer, pl.timeControlStatus != .playing {
            pl.play()
        }
#if canImport(MusicKit) && os(iOS)
        if usesMusicKitPlayback {
            Task { @MainActor in
                try? await ApplicationMusicPlayer.shared.play()
            }
            return
        }
#endif
#if canImport(MediaPlayer) && os(iOS)
        if musicPlayer.playbackState != .playing {
            musicPlayer.play()
        }
#endif
    }

    private func configureSession() throws {
        #if os(iOS)
        try AudioManager.configureSleepPlaybackSession()
        #endif
    }

    private func applyPlaybackOffset(elapsed: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0.05, elapsed.isFinite, elapsed > 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: duration)
    }

    /// Вибрация вместе с рингтоном: достаточно, чтобы разбудить, без «дрели».
    private func startAlarmVibrationLoop() {
        #if canImport(UIKit) && os(iOS)
        let gen = UIImpactFeedbackGenerator(style: .soft)
        gen.prepare()
        alarmHaptics = gen
        let vt = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.alarmHaptics?.impactOccurred(intensity: 0.5)
            self.alarmHaptics?.prepare()
        }
        vibrateTimer = vt
        RunLoop.main.add(vt, forMode: .common)
        #endif
    }

    /// Если трек из медиатеки не поднялся — встроенные музыкальные mp3 из `Ringtones/Musical` (без отдельных wav в корне бандла).
    private func startBundledFallbackMusicalAlarm(elapsed: TimeInterval) {
        startBundledFallbackAlarm(option: AlarmSoundOption.randomMusicalFallback(), elapsed: elapsed)
    }

    private func startBundledFallbackAlarm(option: AlarmSoundOption, elapsed: TimeInterval) {
        let candidates: [AlarmSoundOption] = [option]
            + AlarmSoundOption.musicalSounds.filter { $0 != option }
            + AlarmSoundOption.mechanicalSounds
        for opt in candidates {
            guard let finalURL = opt.ringtonePlaybackURL() else { continue }
            do {
                try configureSession()
                #if os(iOS)
                AudioManager.routeAlarmPlaybackToSpeakerIfPossible()
                #endif
                let p = try AVAudioPlayer(contentsOf: finalURL)
                p.numberOfLoops = -1
                p.volume = opt.category == .musical ? 0.92 : 1.0
                p.prepareToPlay()
                p.currentTime = applyPlaybackOffset(elapsed: elapsed, duration: p.duration)
                p.play()
                player = p
                startAlarmVibrationLoop()
                return
            } catch {
                continue
            }
        }
        startAlarmVibrationLoop()
    }

    private func startLocalFilePlayback(option _: AlarmSoundOption, elapsed: TimeInterval) -> Bool {
        guard AlarmWakeSoundModeStorage.resolvedMode() == .localFile else { return false }
        guard let url = AlarmLocalFileStorage.playbackURL() else { return false }
        do {
            try configureSession()
            #if os(iOS)
            AudioManager.routeAlarmPlaybackToSpeakerIfPossible()
            #endif
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.volume = 1.0
            p.prepareToPlay()
            p.currentTime = applyPlaybackOffset(elapsed: elapsed, duration: p.duration)
            if p.play() {
                player = p
                return true
            }
        } catch {
            // fall through to AVPlayer
        }
        startLocalFileAVPlayerLoop(url: url, elapsed: elapsed)
        return fileLoopPlayer != nil
    }

    private func startLocalFileAVPlayerLoop(url: URL, elapsed: TimeInterval) {
        try? configureSession()
        #if os(iOS)
        AudioManager.routeAlarmPlaybackToSpeakerIfPossible()
        #endif
        let item = AVPlayerItem(url: url)
        let pl = AVPlayer(playerItem: item)
        pl.volume = 1.0
        fileLoopEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak pl] _ in
            pl?.seek(to: .zero)
            pl?.play()
        }
        fileLoopPlayer = pl
        if elapsed <= 0.01 {
            pl.play()
        } else {
            Task { @MainActor in
                do {
                    let duration = try await item.asset.load(.duration)
                    let sec = CMTimeGetSeconds(duration)
                    let pos = self.applyPlaybackOffset(elapsed: elapsed, duration: sec)
                    await pl.seek(to: CMTime(seconds: pos, preferredTimescale: 600))
                } catch {
                    await pl.seek(to: .zero)
                }
                pl.play()
            }
        }
    }

#if canImport(MediaPlayer) && os(iOS)
    private func startAppleMusicAlarm(option _: AlarmSoundOption, elapsed: TimeInterval) async {
        guard AlarmWakeSoundModeStorage.resolvedMode() == .appleMusic else { return }
        guard let selection = AlarmMelodyStorage.load() else {
            startBundledFallbackMusicalAlarm(elapsed: elapsed)
            startAlarmVibrationLoop()
            return
        }
        if MPMediaLibrary.authorizationStatus() != .authorized {
            _ = await withCheckedContinuation { (cont: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
                MPMediaLibrary.requestAuthorization { cont.resume(returning: $0) }
            }
        }
        if let item = AlarmMelodyResolver.resolve(selection: selection) {
            playMPMediaItemAlarm(item: item, elapsed: elapsed)
            startAlarmVibrationLoop()
            return
        }
        #if canImport(MusicKit)
        let sidTrim = selection.playbackStoreID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if await playMusicKitAlarm(selection: selection, storeID: sidTrim, elapsed: elapsed) {
            startAlarmVibrationLoop()
            return
        }
        #endif
        startBundledFallbackMusicalAlarm(elapsed: elapsed)
        startAlarmVibrationLoop()
    }

    private func playMPMediaItemAlarm(item: MPMediaItem, elapsed: TimeInterval) {
#if canImport(MusicKit) && os(iOS)
        usesMusicKitPlayback = false
#endif
        if let cur = AlarmMelodyStorage.load(), cur.playbackStoreID == nil {
            let sid = item.playbackStoreID
            if !sid.isEmpty {
                let migrated = AlarmMelodySelection(
                    persistentID: cur.persistentID,
                    playbackStoreID: sid,
                    title: cur.title,
                    artist: cur.artist
                )
                AlarmMelodyStorage.save(migrated)
            }
        }
        let dur = item.playbackDuration
        let start: TimeInterval = dur > 0.05 ? applyPlaybackOffset(elapsed: elapsed, duration: dur) : 0
        AlarmApplicationMusicPlayer.playAlarmLoop(item: item, startTime: start)
        publishAppleMusicNowPlaying(item: item)
        publishedAppleMusicNowPlaying = true
    }

    #if canImport(MusicKit)
    /// MusicKit: каталог, медиатека по ID, поиск в каталоге, нечёткое совпадение в медиатеке (см. `AlarmAppleMusicPlayback`).
    private func playMusicKitAlarm(selection: AlarmMelodySelection, storeID: String, elapsed: TimeInterval) async -> Bool {
        musicPlayer.stop()
        let status = await MusicAuthorization.request()
        guard status == .authorized else { return false }
        guard let resolved = await AlarmAppleMusicPlayback.resolveSongForAlarm(selection: selection, storeID: storeID) else {
            return false
        }
        do {
            try AudioManager.configureSessionForAppleMusicAlarm()
            let player = ApplicationMusicPlayer.shared
            player.queue = [resolved]
            player.state.repeatMode = .one
            if elapsed > 0.5, let dur = resolved.duration, dur > 0.05 {
                player.playbackTime = applyPlaybackOffset(elapsed: elapsed, duration: dur)
            }
            try await player.play()
            usesMusicKitPlayback = true
            publishedAppleMusicNowPlaying = true
            publishMusicKitNowPlaying(song: resolved)
            return true
        } catch {
            return false
        }
    }

    private func publishMusicKitNowPlaying(song: Song) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artistName
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }
    #endif
#endif

#if canImport(MediaPlayer) && os(iOS)
    private func publishAppleMusicNowPlaying(item: MPMediaItem) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = item.title ?? "Alarm"
        info[MPMediaItemPropertyArtist] = item.artist ?? ""
        if let album = item.albumTitle { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork = item.artwork {
            let size = CGSize(width: 600, height: 600)
            if let image = artwork.image(at: size) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in image }
            }
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func clearAppleMusicNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
#endif
}
