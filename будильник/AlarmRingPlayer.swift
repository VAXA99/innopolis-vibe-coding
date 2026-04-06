import AVFoundation
import Combine
import Foundation
#if canImport(UIKit) && os(iOS)
import AudioToolbox
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
    private var vibrationWorkItems: [DispatchWorkItem] = []
#endif
#if canImport(MediaPlayer) && os(iOS)
    private let musicPlayer = MPMusicPlayerController.applicationMusicPlayer
    private var publishedAppleMusicNowPlaying = false
#endif
#if canImport(MusicKit) && os(iOS)
    /// Когда играет `ApplicationMusicPlayer` (каталог по Store ID) — не смешивать с `MPMusicPlayerController` в reassert/stop.
    private var usesMusicKitPlayback = false
#endif
    private var crescendoTimer: Timer?
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
            p.prepareToPlay()
            p.currentTime = applyPlaybackOffset(elapsed: elapsed, duration: p.duration)
            applyVolumeAndOptionalCrescendo(player: p, option: option)
            p.play()
            player = p
            startAlarmVibrationLoop()
        } catch {
            startBundledFallbackAlarm(option: option, elapsed: elapsed)
        }
    }

    func stop() {
        crescendoTimer?.invalidate()
        crescendoTimer = nil
        vibrateTimer?.invalidate()
        vibrateTimer = nil
#if canImport(UIKit) && os(iOS)
        cancelPendingVibrationWorkItems()
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

    private func baseVolume(for option: AlarmSoundOption) -> Float {
        let cat: Float = option.category == .musical ? 0.92 : 1.0
        return Float(AlarmBehaviorSettings.alarmVolumeMultiplier) * cat
    }

    /// Плавная S-кривая 0…1 для громкости (медленный старт и финиш).
    private static func smoothCrescendoProgress(linear: Float) -> Float {
        let t = min(1, max(0, linear))
        return t * t * (3 - 2 * t)
    }

    private func startCrescendo(on player: AVAudioPlayer, endVolume: Float, duration: TimeInterval) {
        crescendoTimer?.invalidate()
        let steps = max(8, Int(duration / 0.25))
        let startV = min(0.12, max(0.05, endVolume * 0.18))
        player.volume = startV
        var step = 0
        let timer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { [weak self, weak player] t in
            guard let player else {
                t.invalidate()
                return
            }
            step += 1
            let linear = min(1, Float(step) / Float(steps))
            let r = Self.smoothCrescendoProgress(linear: linear)
            player.volume = startV + (endVolume - startV) * r
            if step >= steps {
                t.invalidate()
                player.volume = endVolume
                self?.crescendoTimer = nil
            }
        }
        crescendoTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startCrescendoAVPlayer(player: AVPlayer, endVolume: Float, duration: TimeInterval) {
        crescendoTimer?.invalidate()
        let steps = max(8, Int(duration / 0.25))
        let startV = min(0.12, max(0.05, endVolume * 0.18))
        player.volume = startV
        var step = 0
        let timer = Timer.scheduledTimer(withTimeInterval: duration / Double(steps), repeats: true) { [weak self, weak player] t in
            guard let player else {
                t.invalidate()
                return
            }
            step += 1
            let linear = min(1, Float(step) / Float(steps))
            let r = Self.smoothCrescendoProgress(linear: linear)
            player.volume = startV + (endVolume - startV) * r
            if step >= steps {
                t.invalidate()
                player.volume = endVolume
                self?.crescendoTimer = nil
            }
        }
        crescendoTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyVolumeAndOptionalCrescendo(player: AVAudioPlayer, option: AlarmSoundOption) {
        let end = min(1, max(0.05, baseVolume(for: option)))
        guard AlarmBehaviorSettings.isCrescendoEnabled else {
            player.volume = end
            return
        }
        let dur = TimeInterval(AlarmBehaviorSettings.crescendoRampSeconds)
        startCrescendo(on: player, endVolume: end, duration: dur)
    }

    private func applyVolumeAndOptionalCrescendoAVPlayer(player: AVPlayer, option: AlarmSoundOption) {
        let end = min(1, max(0.05, baseVolume(for: option)))
        guard AlarmBehaviorSettings.isCrescendoEnabled else {
            player.volume = end
            return
        }
        let dur = TimeInterval(AlarmBehaviorSettings.crescendoRampSeconds)
        startCrescendoAVPlayer(player: player, endVolume: end, duration: dur)
    }

    private func applyPlaybackOffset(elapsed: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0.05, elapsed.isFinite, elapsed > 0 else { return 0 }
        return elapsed.truncatingRemainder(dividingBy: duration)
    }

    /// Вибрация: стандартный режим или записанный рисунок (повтор цикла с паузой).
    private func startAlarmVibrationLoop() {
        #if canImport(UIKit) && os(iOS)
        guard AlarmVibrationSettings.isEnabled else { return }
        switch AlarmVibrationSettings.mode {
        case .customPattern:
            let samples = AlarmVibrationSettings.loadCustomPattern()
            guard !samples.isEmpty else {
                startAlarmVibrationLoopStandard()
                return
            }
            prepareImpactGeneratorForCustomPattern()
            let patternEnd = (samples.map(\.offset).max() ?? 0) + 0.12
            let period = patternEnd + AlarmVibrationSettings.patternRepeatGapSeconds
            playCustomVibrationPattern(samples: samples)
            let vt = Timer.scheduledTimer(withTimeInterval: max(0.35, period), repeats: true) { [weak self] _ in
                self?.playCustomVibrationPattern(samples: samples)
            }
            vibrateTimer = vt
            RunLoop.main.add(vt, forMode: .common)
        case .standard:
            startAlarmVibrationLoopStandard()
        }
        #endif
    }

    #if canImport(UIKit) && os(iOS)
    private func prepareImpactGeneratorForCustomPattern() {
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.prepare()
        alarmHaptics = gen
    }

    private func cancelPendingVibrationWorkItems() {
        vibrationWorkItems.forEach { $0.cancel() }
        vibrationWorkItems.removeAll()
    }

    private func playCustomVibrationPattern(samples: [AlarmVibrationSettings.PatternSample]) {
        cancelPendingVibrationWorkItems()
        for s in samples {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if s.systemBuzz {
                    AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                }
                self.alarmHaptics?.impactOccurred(intensity: CGFloat(s.intensity))
                self.alarmHaptics?.prepare()
            }
            vibrationWorkItems.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + s.offset, execute: item)
        }
    }

    private func startAlarmVibrationLoopStandard() {
        guard AlarmVibrationSettings.isEnabled else { return }
        let interval = AlarmVibrationSettings.pulseIntervalSeconds
        let style = AlarmVibrationSettings.style
        if style == .gentle || style == .both {
            let gen = UIImpactFeedbackGenerator(style: .medium)
            gen.prepare()
            alarmHaptics = gen
        } else {
            alarmHaptics = nil
        }
        let vt = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            switch AlarmVibrationSettings.style {
            case .gentle:
                self.alarmHaptics?.impactOccurred(intensity: 0.68)
                self.alarmHaptics?.prepare()
            case .strong:
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            case .both:
                AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                self.alarmHaptics?.impactOccurred(intensity: 0.52)
                self.alarmHaptics?.prepare()
            }
        }
        vibrateTimer = vt
        RunLoop.main.add(vt, forMode: .common)
    }
    #endif

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
                p.prepareToPlay()
                p.currentTime = applyPlaybackOffset(elapsed: elapsed, duration: p.duration)
                applyVolumeAndOptionalCrescendo(player: p, option: opt)
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
            p.prepareToPlay()
            p.currentTime = applyPlaybackOffset(elapsed: elapsed, duration: p.duration)
            applyVolumeAndOptionalCrescendo(player: p, option: .mechDigitalBuzzer)
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
        applyVolumeAndOptionalCrescendoAVPlayer(player: pl, option: .mechDigitalBuzzer)
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
