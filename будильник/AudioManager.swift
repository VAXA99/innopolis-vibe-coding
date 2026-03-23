import Foundation
import AVFoundation

enum AudioManagerError: Error {
    case audioFileNotFound
    case audioBufferLoadFailed
}

final class AudioManager {
    private var sessionID: UUID = UUID()

    private let fadeInDuration: TimeInterval = 1.6
    private let fadeOutDuration: TimeInterval = 2.0

    private let volumeLowPassHighCutoff: Double = 20_000
    private let volumeLowPassLowCutoff: Double = 900

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var mixerNode: AVAudioMixerNode?
    private var eqNode: AVAudioUnitEQ?
    private var reverbNode: AVAudioUnitReverb?

    private var sleepTask: Task<Void, Never>?
    private var volumeAutomationTask: Task<Void, Never>?

    private var onFinished: (() -> Void)?
    private var didFinish = false

    private var bufferCache: [SleepSound: AVAudioPCMBuffer] = [:]
    private let cacheLock = NSLock()

    func startSleep(
        sound: SleepSound,
        volume: Float,
        softness: Float,
        space: Float,
        durationMinutes: Int,
        onFinished: @escaping () -> Void
    ) async {
        // Invalidate any in-flight automation/fade tasks from previous sessions.
        sessionID = UUID()
        let localSessionID = sessionID

        didFinish = false
        self.onFinished = onFinished
        sleepTask?.cancel()
        sleepTask = nil
        volumeAutomationTask?.cancel()
        volumeAutomationTask = nil
        playerNode?.stop()
        engine?.stop()
        teardown()

        do {
            try configureAudioSession()
            let buffer = try await loadBuffer(for: sound)

            if Task.isCancelled { return }

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let mixer = AVAudioMixerNode()

            let eq = AVAudioUnitEQ(numberOfBands: 1)
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.mediumRoom)

            engine.attach(player)
            engine.attach(eq)
            engine.attach(reverb)
            engine.attach(mixer)

            let format = buffer.format
            engine.connect(player, to: eq, format: format)
            engine.connect(eq, to: reverb, format: format)
            engine.connect(reverb, to: mixer, format: format)
            engine.connect(mixer, to: engine.mainMixerNode, format: format)

            mixer.outputVolume = 0.0

            configureSoftness(eq: eq, softness: softness)
            configureSpace(reverb: reverb, space: space, player: player)

            await player.scheduleBuffer(buffer, at: nil, options: [.loops, .interrupts])

            self.engine = engine
            self.playerNode = player
            self.mixerNode = mixer
            self.eqNode = eq
            self.reverbNode = reverb

            try engine.start()
            player.play()

            // Start with a silent fade-in.
            await rampMixerVolume(to: clamp01(volume), duration: fadeInDuration, sessionID: localSessionID)

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

        Task { [weak self] in
            guard let self else { return }
            await self.fadeOutAndStop(force: true, sessionID: localSessionID)
        }
    }

    func applySoundSettings(volume: Float, softness: Float, space: Float) {
        guard let eq = eqNode, let reverb = reverbNode else { return }

        configureSoftness(eq: eq, softness: softness)
        configureSpace(reverb: reverb, space: space, player: playerNode)

        volumeAutomationTask?.cancel()
        volumeAutomationTask = Task { [weak self] in
            guard let self, let mixer = self.mixerNode else { return }
            await self.rampMixerVolume(to: self.clamp01(volume), duration: 0.25)
        }
    }

    // MARK: - Audio Pipeline

    private func configureSoftness(eq: AVAudioUnitEQ, softness: Float) {
        // softness: 0 => bright, 1 => muffled (low-pass cutoff lowered).
        let s = clamp01(softness)
        let cutoff = Float(volumeLowPassHighCutoff) * (1.0 - s) + Float(volumeLowPassLowCutoff) * s

        let band = eq.bands[0]
        band.filterType = .lowPass
        band.frequency = cutoff
        band.bandwidth = 0.55
        band.gain = 0
    }

    private func configureSpace(reverb: AVAudioUnitReverb, space: Float, player: AVAudioPlayerNode?) {
        let w = clamp01(space)

        // Interpret "space" as perceived width via a reverb wet/dry mix.
        // Also apply a subtle pan shift for extra spatial feel.
        reverb.wetDryMix = w * 55.0
        player?.pan = (w - 0.5) * 0.35
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    private func loadBuffer(for sound: SleepSound) async throws -> AVAudioPCMBuffer {
        cacheLock.lock()
        if let cached = bufferCache[sound] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let url = sound.resourceURL else { throw AudioManagerError.audioFileNotFound }

        let buffer: AVAudioPCMBuffer = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let file = try AVAudioFile(forReading: url)
                    let format = file.processingFormat
                    let frameCapacity = AVAudioFrameCount(file.length)

                    let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)!
                    pcmBuffer.frameLength = frameCapacity
                    try file.read(into: pcmBuffer)
                    continuation.resume(returning: pcmBuffer)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        cacheLock.lock()
        bufferCache[sound] = buffer
        cacheLock.unlock()
        return buffer
    }

    private func rampMixerVolume(to target: Float, duration: TimeInterval) async {
        await rampMixerVolume(to: target, duration: duration, sessionID: sessionID)
    }

    private func rampMixerVolume(to target: Float, duration: TimeInterval, sessionID: UUID) async {
        guard let mixer = mixerNode else { return }
        guard self.sessionID == sessionID else { return }

        let start = mixer.outputVolume
        let step: TimeInterval = 0.05
        let steps = max(1, Int(duration / step))

        for i in 0...steps {
            if Task.isCancelled { return }
            guard self.sessionID == sessionID else { return }
            let t = Float(i) / Float(steps)
            mixer.outputVolume = start + (target - start) * t
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
    }

    private func fadeOutAndStop(force: Bool = false, sessionID: UUID) async {
        guard self.sessionID == sessionID else { return }
        guard let mixer = mixerNode else {
            finishIfNeeded()
            teardown()
            return
        }

        if force {
            guard self.sessionID == sessionID else { return }
            mixer.outputVolume = 0.0
            playerNode?.stop()
            engine?.stop()
            teardown()
            finishIfNeeded()
            return
        }

        let startVolume = mixer.outputVolume
        await rampMixerVolume(to: 0.0, duration: fadeOutDuration, sessionID: sessionID)
        if startVolume > 0.001 {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        guard self.sessionID == sessionID else { return }
        playerNode?.stop()
        engine?.stop()
        teardown()
        finishIfNeeded()
    }

    private func teardown() {
        engine = nil
        playerNode = nil
        mixerNode = nil
        eqNode = nil
        reverbNode = nil
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

