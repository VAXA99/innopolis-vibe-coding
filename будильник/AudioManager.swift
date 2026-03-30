import Foundation
import AVFoundation
import MediaPlayer

enum AudioManagerError: Error {
    case audioFileNotFound
}

/// Sleep playback via `AVAudioPlayer` (reliable loops; avoids silent `AVAudioEngine` graph issues on device).
final class AudioManager {
    private var sessionID = UUID()

    private let fadeInDuration: TimeInterval = 1.6
    private let fadeOutDuration: TimeInterval = 2.0

    private var sleepPlayer: AVAudioPlayer?
    private var sleepSecondaryPlayer: AVAudioPlayer?
    private var sleepLoopTask: Task<Void, Never>?
    private var sleepTargetVolume: Float = 0.75
    private var loopCrossfadeDuration: TimeInterval = 1.2

    private var sleepTask: Task<Void, Never>?
    private var volumeAutomationTask: Task<Void, Never>?

    private var onFinished: (() -> Void)?
    private var didFinish = false

    private var previewPlayer: AVAudioPlayer?

    func startSleep(
        sound: SleepSound,
        volume: Float,
        softness _: Float,
        space _: Float,
        brainFrequencyHz _: Float,
        durationMinutes: Int,
        onFinished: @escaping () -> Void
    ) async {
        sessionID = UUID()
        let localSessionID = sessionID

        didFinish = false
        self.onFinished = onFinished
        sleepTask?.cancel()
        sleepTask = nil
        volumeAutomationTask?.cancel()
        volumeAutomationTask = nil
        sleepLoopTask?.cancel()
        sleepLoopTask = nil
        stopPreview()
        sleepPlayer?.stop()
        sleepSecondaryPlayer?.stop()
        sleepPlayer = nil
        sleepSecondaryPlayer = nil

        do {
            try configureAudioSession()
            guard let url = sound.resourceURL else {
                finishIfNeeded()
                return
            }

            let playerA = try AVAudioPlayer(contentsOf: url)
            let playerB = try AVAudioPlayer(contentsOf: url)
            playerA.numberOfLoops = 0
            playerB.numberOfLoops = 0
            playerA.volume = 0
            playerB.volume = 0
            playerA.prepareToPlay()
            playerB.prepareToPlay()
            sleepPlayer = playerA
            sleepSecondaryPlayer = playerB
            sleepTargetVolume = clamp01(volume)
            loopCrossfadeDuration = max(0.35, sound.loopCrossfadeDuration)
            playerA.currentTime = 0
            playerA.play()
            startSeamlessLoopTask(sessionID: localSessionID)

            await rampSleepBlendVolume(to: sleepTargetVolume, duration: fadeInDuration, sessionID: localSessionID)

            let totalSeconds = max(0, durationMinutes) * 60
            if totalSeconds > 0 {
                sleepTask = Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: UInt64(totalSeconds) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    await self.fadeOutAndStop(sessionID: localSessionID)
                }
            } else {
                await fadeOutAndStop(sessionID: localSessionID)
            }
        } catch {
            finishIfNeeded()
        }
    }

    func stopSleep() {
        sessionID = UUID()
        let localSessionID = sessionID
        sleepTask?.cancel()
        sleepTask = nil
        volumeAutomationTask?.cancel()
        volumeAutomationTask = nil
        sleepLoopTask?.cancel()
        sleepLoopTask = nil
        stopPreview()

        Task { [weak self] in
            guard let self else { return }
            await self.fadeOutAndStop(force: true, sessionID: localSessionID)
        }
    }

    /// Остановить сон без вызова `onFinished` (например, по таймеру — дальше звучит будильник).
    func stopPlaybackSilently() {
        sessionID = UUID()
        sleepTask?.cancel()
        sleepTask = nil
        volumeAutomationTask?.cancel()
        volumeAutomationTask = nil
        sleepLoopTask?.cancel()
        sleepLoopTask = nil
        stopPreview()
        sleepPlayer?.stop()
        sleepSecondaryPlayer?.stop()
        sleepPlayer = nil
        sleepSecondaryPlayer = nil
        onFinished = nil
        didFinish = true
    }

    func applySoundSettings(volume: Float, softness _: Float, space _: Float, brainFrequencyHz _: Float) {
        guard sleepPlayer != nil else { return }
        sleepTargetVolume = clamp01(volume)

        volumeAutomationTask?.cancel()
        volumeAutomationTask = Task { [weak self] in
            guard let self else { return }
            await self.rampSleepBlendVolume(to: self.sleepTargetVolume, duration: 0.25, sessionID: self.sessionID)
        }
    }

    func previewSound(sound: SleepSound, volume: Float) {
        stopPreview()
        guard let url = sound.resourceURL else { return }
        do {
            try configureAudioSession()
            let player = try AVAudioPlayer(contentsOf: url)
            player.currentTime = 0
            player.volume = clamp01(volume)
            player.numberOfLoops = 0
            player.prepareToPlay()
            player.play()
            previewPlayer = player
        } catch {
            previewPlayer = nil
        }
    }

    func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
    }

    private func configureAudioSession() throws {
        try Self.configureSleepPlaybackSession()
    }

    /// Единая настройка сессии: фон + динамик + наушники/Bluetooth.
    static func configureSleepPlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]
        )
        try session.setActive(true, options: [])
        // Не вызываем overrideOutputAudioPort(.speaker): при AirPods/Bluetooth это часто обнуляет звук.
    }

    /// Будильник через `MPMusicPlayerController.applicationMusicPlayer`: не форсим нижний динамик и не трогаем `defaultToSpeaker`.
    /// Иначе на части устройств вместо музыки — писк / «ультразвук» / искажение из‑за неверного маршрута и сессии.
    static func configureSessionForAppleMusicAlarm() throws {
        let session = AVAudioSession.sharedInstance()
        #if os(iOS)
        try? session.overrideOutputAudioPort(.none)
        #endif
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.allowBluetoothA2DP, .allowAirPlay]
        )
        try session.setActive(true, options: [])
    }

    /// Короткий предпросмотр рингтона в настройках.
    static func configureAlarmPreviewSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .default,
            options: [.defaultToSpeaker, .mixWithOthers]
        )
        try session.setActive(true, options: [])
    }

    /// После превью вернуть маршрут (иначе может «залипнуть» только динамик).
    static func resetAlarmPreviewOutputOverride() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
        #endif
    }

    /// Временно направить превью на нижний динамик (иначе на части устройств слышно «тишину» в разговорном динамике).
    static func routeAlarmPreviewToLoudSpeakerIfPossible() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        #endif
    }

    /// Будильник: тот же маршрут, иначе MP3 может «гулять» в разговорном / давать странный тон.
    static func routeAlarmPlaybackToSpeakerIfPossible() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        #endif
    }

    /// После сворачивания или прерывания — снова включить сессию и воспроизведение.
    func reassertSleepPlaybackIfNeeded() {
        guard sleepPlayer != nil else { return }
        try? Self.configureSleepPlaybackSession()
        sleepPlayer?.play()
        if let secondary = sleepSecondaryPlayer, secondary.volume > 0.001 {
            secondary.play()
        }
    }

    static func publishSleepNowPlaying(title: String, subtitle: String) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle
        ]
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    static func clearSleepNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func rampPlayerVolume(to target: Float, duration: TimeInterval, sessionID: UUID) async {
        guard let player = sleepPlayer else { return }
        guard self.sessionID == sessionID else { return }

        let start = player.volume
        let step: TimeInterval = 0.05
        let steps = max(1, Int(duration / step))

        for i in 0...steps {
            if Task.isCancelled { return }
            guard self.sessionID == sessionID else { return }
            guard let p = sleepPlayer, p === player else { return }
            let t = Float(i) / Float(steps)
            p.volume = start + (target - start) * t
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
    }

    private func rampSleepBlendVolume(to target: Float, duration: TimeInterval, sessionID: UUID) async {
        guard self.sessionID == sessionID else { return }
        guard let p1 = sleepPlayer else { return }
        let p2 = sleepSecondaryPlayer

        let start1 = p1.volume
        let start2 = p2?.volume ?? 0
        let total = max(0.001, start1 + start2)
        let end1 = target * (start1 / total)
        let end2 = target * (start2 / total)

        let step: TimeInterval = 0.05
        let steps = max(1, Int(duration / step))
        for i in 0...steps {
            if Task.isCancelled { return }
            guard self.sessionID == sessionID else { return }
            let t = Float(i) / Float(steps)
            p1.volume = start1 + (end1 - start1) * t
            p2?.volume = start2 + (end2 - start2) * t
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
    }

    private func startSeamlessLoopTask(sessionID: UUID) {
        sleepLoopTask?.cancel()
        sleepLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard self.sessionID == sessionID else { return }
                guard let current = self.sleepPlayer, let standby = self.sleepSecondaryPlayer else { return }
                guard current.duration > 2.0 else { return }

                let crossfade = min(self.loopCrossfadeDuration, max(0.35, current.duration * 0.25))
                let remain = max(0.05, (current.duration - current.currentTime) - crossfade)
                try? await Task.sleep(nanoseconds: UInt64(remain * 1_000_000_000))
                guard !Task.isCancelled, self.sessionID == sessionID else { return }

                standby.currentTime = 0
                standby.volume = 0
                standby.play()

                let startTarget = self.sleepTargetVolume
                let step: TimeInterval = 0.04
                let steps = max(1, Int(crossfade / step))
                for i in 0...steps {
                    if Task.isCancelled { return }
                    guard self.sessionID == sessionID else { return }
                    let t = Float(i) / Float(steps)
                    current.volume = startTarget * (1 - t)
                    standby.volume = startTarget * t
                    try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                }

                current.stop()
                current.currentTime = 0
                current.volume = 0
                self.sleepPlayer = standby
                self.sleepSecondaryPlayer = current
            }
        }
    }

    private func fadeOutAndStop(force: Bool = false, sessionID: UUID) async {
        guard self.sessionID == sessionID else { return }

        guard let player = sleepPlayer else {
            finishIfNeeded()
            return
        }

        if force {
            player.stop()
            sleepSecondaryPlayer?.stop()
            sleepPlayer = nil
            sleepSecondaryPlayer = nil
            finishIfNeeded()
            return
        }

        sleepLoopTask?.cancel()
        sleepLoopTask = nil

        let startVolume = player.volume + (sleepSecondaryPlayer?.volume ?? 0)
        await rampSleepBlendVolume(to: 0, duration: fadeOutDuration, sessionID: sessionID)
        if startVolume > 0.001 {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        guard self.sessionID == sessionID else { return }
        player.stop()
        sleepSecondaryPlayer?.stop()
        sleepPlayer = nil
        sleepSecondaryPlayer = nil
        finishIfNeeded()
    }

    private func finishIfNeeded() {
        guard !didFinish else { return }
        didFinish = true
        let callback = onFinished
        onFinished = nil

        Task { @MainActor in
            callback?()
        }
    }

    private func clamp01(_ v: Float) -> Float {
        min(max(v, 0), 1)
    }
}
