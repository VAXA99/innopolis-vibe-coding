import SwiftUI
import Foundation
import Combine

enum SleepTonePreset: String, CaseIterable, Identifiable {
    case longSleep
    case windDown
    case brightDream

    var id: String { rawValue }

    var title: String {
        switch self {
        case .longSleep: return "Long sleep"
        case .windDown: return "Wind-down"
        case .brightDream: return "Bright dream"
        }
    }

    var subtitle: String {
        switch self {
        case .longSleep: return "Steady, deep blend"
        case .windDown: return "Faster drift-off"
        case .brightDream: return "Airy, lighter mix"
        }
    }
}

struct SleepSessionRecord: Identifiable, Hashable {
    let id = UUID()
    let startDate: Date
    let endDate: Date
    let durationMinutes: Int
    let stoppedEarly: Bool
    let recommendation: String
    let activityLevel: Int
}

@MainActor
final class SleepViewModel: ObservableObject {
    @Published var selectedSound: SleepSound = .rain

    // 0...1 sliders
    @Published var volume: Double = 0.75
    @Published var softness: Double = 0.35
    @Published var space: Double = 0.55
    @Published var brainFrequencyHz: Double = 432

    @Published var timerMinutes: Int = 15
    @Published var wakeWindowMinutes: Int = 30
    @Published var isRunning: Bool = false
    @Published var remainingSeconds: Int = 0
    @Published var lastSession: SleepSessionRecord?
    @Published var sessionHistory: [SleepSessionRecord] = []

    private let audioManager: AudioManager
    private let spatialMixer = SpatialMixerAudioManager()
    private var usesSpatialMix = false

    /// Sounds placed on the spatial platform (Step 2). Empty => legacy single-sound path.
    @Published var spatialPlacedSounds: [SpatialPlacedSound] = []

    private var countdownTask: Task<Void, Never>?
    private var sessionStartDate: Date?
    private var didFinishSession = false

    init(audioManager: AudioManager = AudioManager()) {
        self.audioManager = audioManager
    }

    /// One layer per `SleepSound` — adding again replaces the previous position.
    func setSpatialSoundAt(_ sound: SleepSound, unitOffset: CGPoint) {
        spatialPlacedSounds.removeAll { $0.sound == sound }
        spatialPlacedSounds.append(SpatialPlacedSound(sound: sound, unitOffset: SpatialPlacedSound.clampedToUnitCircle(unitOffset)))
        syncSpatialPreview()
    }

    private var spatialPreviewGeneration = 0


    func removeSpatialNode(id: UUID) {
        spatialPlacedSounds.removeAll { $0.id == id }
        syncSpatialPreview()
    }

    func updateSpatialNode(id: UUID, unitOffset: CGPoint) {
        guard let i = spatialPlacedSounds.firstIndex(where: { $0.id == id }) else { return }
        var item = spatialPlacedSounds[i]
        item.unitOffset = unitOffset
        spatialPlacedSounds[i] = item
    }

    /// Commit node position after drag (clamped to ring).
    func commitSpatialNode(id: UUID, unitOffset: CGPoint) {
        guard let i = spatialPlacedSounds.firstIndex(where: { $0.id == id }) else { return }
        var item = spatialPlacedSounds[i]
        item.unitOffset = SpatialPlacedSound.clampedToUnitCircle(unitOffset)
        spatialPlacedSounds[i] = item
    }

    /// Live preview — incremental: existing layers keep playing; new layers fade in; no full stop/rebuild.
    func syncSpatialPreview() {
        guard !isRunning else { return }
        spatialPreviewGeneration += 1
        let gen = spatialPreviewGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard gen == self.spatialPreviewGeneration else { return }
            guard !self.spatialPlacedSounds.isEmpty else {
                self.spatialMixer.stop()
                return
            }
            let vols = SpatialPlacedSound.normalizedVolumes(for: self.spatialPlacedSounds)
            guard gen == self.spatialPreviewGeneration else { return }
            self.spatialMixer.sync(
                placed: self.spatialPlacedSounds,
                volumes: vols,
                softness: Float(self.softness),
                space: Float(self.space),
                brainFrequencyHz: Float(self.brainFrequencyHz)
            )
        }
    }

    /// Quick tone recipes (Hz + softness + space). Exploratory — not medical advice.
    func applySleepTonePreset(_ preset: SleepTonePreset) {
        switch preset {
        case .longSleep:
            brainFrequencyHz = 380
            softness = 0.58
            space = 0.42
        case .windDown:
            brainFrequencyHz = 260
            softness = 0.42
            space = 0.38
        case .brightDream:
            brainFrequencyHz = 520
            softness = 0.22
            space = 0.72
        }
        applySpatialMasterEffects()
    }

    /// Slider changes while previewing (volume + stereo width curve — no engine rebuild).
    func applySpatialMasterEffects() {
        guard !isRunning else { return }
        guard !spatialPlacedSounds.isEmpty else { return }
        spatialMixer.updateGlobalEffects(
            softness: Float(softness),
            space: Float(space),
            brainFrequencyHz: Float(brainFrequencyHz)
        )
    }

    /// Only rebalance volumes while dragging nodes (no engine restart).
    func updateSpatialMixVolumes() {
        guard !isRunning else { return }
        let vols = SpatialPlacedSound.normalizedVolumes(for: spatialPlacedSounds)
        spatialMixer.updateVolumes(vols)
    }

    /// Live volume preview while dragging — uses temporary offsets without publishing every frame.
    func updateSpatialMixVolumesWithOverrides(_ unitOffsetsById: [UUID: CGPoint]) {
        guard !isRunning else { return }
        var items = spatialPlacedSounds
        for (id, pt) in unitOffsetsById {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            items[i].unitOffset = pt
        }
        let vols = SpatialPlacedSound.normalizedVolumes(for: items)
        spatialMixer.updateVolumes(vols)
    }

    func stopSpatialPreview() {
        guard !isRunning else { return }
        spatialMixer.stop()
    }

    private func dominantSpatialSound() -> SleepSound {
        spatialPlacedSounds.max(by: { $0.radialGain() < $1.radialGain() })?.sound ?? .rain
    }

    /// Label for sleep mode UI (dominant layer + layer count).
    func mixSummaryLabel() -> String {
        if spatialPlacedSounds.isEmpty {
            return selectedSound.displayName
        }
        let dominant = dominantSpatialSound()
        let count = spatialPlacedSounds.count
        return count > 1 ? "\(dominant.displayName) · \(count) layers" : dominant.displayName
    }

    func startSleep() {
        guard !isRunning else { return }
        isRunning = true
        didFinishSession = false
        sessionStartDate = Date()
        remainingSeconds = max(0, timerMinutes * 60)
        startCountdown()

        if !spatialPlacedSounds.isEmpty {
            usesSpatialMix = true
            selectedSound = dominantSpatialSound()
            let vols = SpatialPlacedSound.normalizedVolumes(for: spatialPlacedSounds)
            spatialMixer.sync(
                placed: spatialPlacedSounds,
                volumes: vols,
                softness: Float(softness),
                space: Float(space),
                brainFrequencyHz: Float(brainFrequencyHz)
            )
            return
        }

        usesSpatialMix = false
        let sound = selectedSound
        let volume = Float(self.volume)
        let softness = Float(self.softness)
        let space = Float(self.space)
        let durationMinutes = timerMinutes

        Task { [weak self] in
            guard let self else { return }
            await self.audioManager.startSleep(
                sound: sound,
                volume: volume,
                softness: softness,
                space: space,
                brainFrequencyHz: Float(self.brainFrequencyHz),
                durationMinutes: durationMinutes
            ) { [weak self] in
                Task { @MainActor in
                    self?.finishSession(stoppedEarly: false)
                }
            }
        }
    }

    func stopSleep() {
        guard isRunning else { return }
        if usesSpatialMix {
            spatialMixer.stop()
            usesSpatialMix = false
        } else {
            audioManager.stopSleep()
        }
        finishSession(stoppedEarly: true)
    }

    func previewSelectedSound() {
        guard !isRunning else { return }
        audioManager.previewSound(sound: selectedSound, volume: Float(volume))
    }

    func markAsWokeUp() {
        lastSession = nil
    }

    func applySoundSettingsIfRunning() {
        guard isRunning else { return }
        if usesSpatialMix {
            spatialMixer.updateGlobalEffects(
                softness: Float(softness),
                space: Float(space),
                brainFrequencyHz: Float(brainFrequencyHz)
            )
        } else {
            audioManager.applySoundSettings(
                volume: Float(volume),
                softness: Float(softness),
                space: Float(space),
                brainFrequencyHz: Float(brainFrequencyHz)
            )
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRunning && self.remainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.remainingSeconds = max(0, self.remainingSeconds - 1)
            }
            guard self.isRunning, !Task.isCancelled else { return }
            if self.usesSpatialMix {
                self.spatialMixer.stop()
                self.usesSpatialMix = false
                self.finishSession(stoppedEarly: false)
            }
        }
    }

    private func finishSession(stoppedEarly: Bool) {
        guard !didFinishSession else { return }
        didFinishSession = true
        isRunning = false
        countdownTask?.cancel()
        countdownTask = nil

        let end = Date()
        let start = sessionStartDate ?? end
        let duration = max(1, Int(end.timeIntervalSince(start) / 60))
        let recommendation = Self.recommendation(for: duration, stoppedEarly: stoppedEarly)
        let record = SleepSessionRecord(
            startDate: start,
            endDate: end,
            durationMinutes: duration,
            stoppedEarly: stoppedEarly,
            recommendation: recommendation,
            activityLevel: Int.random(in: 45...95)
        )
        lastSession = record
        sessionHistory.insert(record, at: 0)
        if sessionHistory.count > 14 {
            sessionHistory = Array(sessionHistory.prefix(14))
        }
    }

    private static func recommendation(for durationMinutes: Int, stoppedEarly: Bool) -> String {
        if stoppedEarly {
            return "Сон завершён рано. Попробуй лечь на 20 минут раньше и не трогать телефон перед сном."
        }
        if durationMinutes < 360 {
            return "Сна было мало. Сегодня лучше лечь раньше, чтобы набрать хотя бы 7 часов."
        }
        if durationMinutes < 450 {
            return "Хороший прогресс. Для стабильной энергии удерживай одинаковое время отбоя."
        }
        return "Отличный сон. Продолжай тот же ритм — утро будет ещё легче."
    }
}

