import Foundation
import AVFoundation

/// Reliable spatial mix: one `AVAudioPlayer` per layer (no `AVAudioEngine` — avoids silent output on device).
/// Softness / space / Hz adjust **volume + stereo pan** so sliders are audible without a fragile DSP graph.
@MainActor
final class SpatialMixerAudioManager {
    private var players: [UUID: AVAudioPlayer] = [:]
    private var soundById: [UUID: SleepSound] = [:]
    private var baseVolumes: [UUID: Float] = [:]
    private var fadeTasks: [UUID: Task<Void, Never>] = [:]

    private var softness: Float = 0.35
    private var space: Float = 0.55
    private var brainHz: Float = 432

    private(set) var isRunning = false
    private let fadeInDuration: TimeInterval = 1.15

    /// Adds/removes layers incrementally; applies tone curve from sliders.
    func sync(
        placed: [SpatialPlacedSound],
        volumes: [UUID: Float],
        softness: Float,
        space: Float,
        brainFrequencyHz: Float
    ) {
        self.softness = softness
        self.space = space
        self.brainHz = brainFrequencyHz

        if placed.isEmpty {
            stopInternal()
            return
        }

        do {
            try configureAudioSession()
        } catch {
            #if DEBUG
            print("SpatialMixer: session", error)
            #endif
        }

        let targetIds = Set(placed.map(\.id))
        for id in players.keys where !targetIds.contains(id) {
            removePlayer(id: id)
        }

        for item in placed {
            let base = Float(volumes[item.id] ?? 0)
            baseVolumes[item.id] = base

            if players[item.id] != nil {
                if soundById[item.id] != item.sound {
                    removePlayer(id: item.id)
                    let fadeIn = !players.isEmpty
                    addNewLayer(item: item, baseVolume: base, fadeIn: fadeIn)
                } else {
                    cancelFade(for: item.id)
                    applyOutput(for: item.id)
                }
            } else {
                let fadeIn = !players.isEmpty
                addNewLayer(item: item, baseVolume: base, fadeIn: fadeIn)
            }
        }

        isRunning = !players.isEmpty
    }

    func updateGlobalEffects(softness: Float, space: Float, brainFrequencyHz: Float) {
        guard engineHasLayers else { return }
        for id in Array(fadeTasks.keys) {
            cancelFade(for: id)
        }
        self.softness = softness
        self.space = space
        self.brainHz = brainFrequencyHz
        applyOutputCurveToAll()
    }

    private var engineHasLayers: Bool {
        !players.isEmpty
    }

    func start(
        placed: [SpatialPlacedSound],
        volumes: [UUID: Float],
        softness: Float,
        space: Float,
        brainFrequencyHz: Float
    ) {
        sync(placed: placed, volumes: volumes, softness: softness, space: space, brainFrequencyHz: brainFrequencyHz)
    }

    func updateVolumes(_ volumes: [UUID: Float]) {
        for (id, v) in volumes {
            cancelFade(for: id)
            baseVolumes[id] = v
        }
        applyOutputCurveToAll()
    }

    func stop() {
        stopInternal()
    }

    // MARK: - Output curve (no AVAudioEngine — perceptual stand-in for EQ / width)

    private func softnessMultiplier() -> Float {
        let s = min(max(softness, 0), 1)
        return 0.68 + 0.32 * (1 - s)
    }

    private func hzMultiplier() -> Float {
        let hz = min(max(brainHz, 120), 600)
        return 0.86 + 0.14 * Float((hz - 120) / 480)
    }

    private func outputVolume(base: Float) -> Float {
        min(1, max(0, base * softnessMultiplier() * hzMultiplier()))
    }

    private func pan(for id: UUID) -> Float {
        let sp = min(max(space, 0), 1)
        let w = Float((sp - 0.5) * 1.5)
        let sign: Float = (abs(id.uuidString.hash) % 2 == 0) ? 1 : -1
        return min(1, max(-1, w * sign))
    }

    private func applyOutput(for id: UUID) {
        guard let p = players[id], let b = baseVolumes[id] else { return }
        p.volume = outputVolume(base: b)
        p.pan = pan(for: id)
    }

    private func applyOutputCurveToAll() {
        for id in players.keys {
            applyOutput(for: id)
        }
    }

    // MARK: - Layers

    private func addNewLayer(item: SpatialPlacedSound, baseVolume: Float, fadeIn: Bool) {
        guard let url = item.sound.resourceURL else {
            #if DEBUG
            print("SpatialMixer: missing URL for \(item.sound.fileResourceName)")
            #endif
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            #if DEBUG
            print("SpatialMixer: missing file \(url.path)")
            #endif
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.prepareToPlay()
            baseVolumes[item.id] = baseVolume
            players[item.id] = player
            soundById[item.id] = item.sound

            let target = outputVolume(base: baseVolume)
            if fadeIn {
                player.volume = 0
                player.pan = pan(for: item.id)
            } else {
                player.volume = target
                player.pan = pan(for: item.id)
            }

            player.play()

            if fadeIn && target > 0.001 {
                runFadeIn(id: item.id, toBase: baseVolume)
            } else {
                applyOutput(for: item.id)
            }
        } catch {
            #if DEBUG
            print("SpatialMixer: add layer failed", error)
            #endif
        }
    }

    private func runFadeIn(id: UUID, toBase base: Float) {
        cancelFade(for: id)
        let target = outputVolume(base: base)
        let steps = 28
        let stepNanos = UInt64((fadeInDuration / Double(steps)) * 1_000_000_000)
        fadeTasks[id] = Task { @MainActor in
            for step in 1...steps {
                if Task.isCancelled { return }
                guard let p = self.players[id] else { return }
                let t = Float(step) / Float(steps)
                p.volume = target * t
                p.pan = self.pan(for: id)
                try? await Task.sleep(nanoseconds: stepNanos)
            }
            if !Task.isCancelled {
                self.applyOutput(for: id)
            }
            self.fadeTasks[id] = nil
        }
    }

    private func cancelFade(for id: UUID) {
        fadeTasks[id]?.cancel()
        fadeTasks[id] = nil
    }

    private func removePlayer(id: UUID) {
        cancelFade(for: id)
        players[id]?.stop()
        players.removeValue(forKey: id)
        soundById.removeValue(forKey: id)
        baseVolumes.removeValue(forKey: id)
    }

    private func stopInternal() {
        isRunning = false
        for id in players.keys {
            cancelFade(for: id)
            players[id]?.stop()
        }
        players.removeAll()
        soundById.removeAll()
        baseVolumes.removeAll()
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
    }
}
