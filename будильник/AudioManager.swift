import Foundation
import AVFoundation

enum AudioManagerError: Error {
    case audioFileNotFound
}

/// Sleep playback via `AVAudioPlayer` (reliable loops; avoids silent `AVAudioEngine` graph issues on device).
final class AudioManager {
    private var sessionID = UUID()

    private let fadeInDuration: TimeInterval = 1.6
    private let fadeOutDuration: TimeInterval = 2.0

    private var sleepPlayer: AVAudioPlayer?

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
        stopPreview()
        sleepPlayer?.stop()
        sleepPlayer = nil

        do {
            try configureAudioSession()
            guard let url = sound.resourceURL else {
                finishIfNeeded()
                return
            }

            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            sleepPlayer = player
            player.play()

            await rampPlayerVolume(to: clamp01(volume), duration: fadeInDuration, sessionID: localSessionID)

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
        stopPreview()

        Task { [weak self] in
            guard let self else { return }
            await self.fadeOutAndStop(force: true, sessionID: localSessionID)
        }
    }

    func applySoundSettings(volume: Float, softness _: Float, space _: Float, brainFrequencyHz _: Float) {
        guard sleepPlayer != nil else { return }

        volumeAutomationTask?.cancel()
        volumeAutomationTask = Task { [weak self] in
            guard let self else { return }
            await self.rampPlayerVolume(to: self.clamp01(volume), duration: 0.25, sessionID: self.sessionID)
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
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
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

    private func fadeOutAndStop(force: Bool = false, sessionID: UUID) async {
        guard self.sessionID == sessionID else { return }

        guard let player = sleepPlayer else {
            finishIfNeeded()
            return
        }

        if force {
            player.stop()
            sleepPlayer = nil
            finishIfNeeded()
            return
        }

        let startVolume = player.volume
        await rampPlayerVolume(to: 0, duration: fadeOutDuration, sessionID: sessionID)
        if startVolume > 0.001 {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        guard self.sessionID == sessionID else { return }
        player.stop()
        sleepPlayer = nil
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
