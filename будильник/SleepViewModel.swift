import SwiftUI
import Foundation
import Combine
import AVFoundation
import UIKit
import UserNotifications

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

enum SleepUIMode {
    /// Идёт таймер сна, можно остановить раньше.
    case sleeping
    /// Таймер закончился — звучит будильник внутри приложения.
    case alarmRinging
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
    @Published var sleepUIMode: SleepUIMode = .sleeping
    @Published var remainingSeconds: Int = 0
    @Published var lastSession: SleepSessionRecord?
    @Published var sessionHistory: [SleepSessionRecord] = []

    private let audioManager: AudioManager
    private let spatialMixer = SpatialMixerAudioManager()
    private let alarmRingPlayer = AlarmRingPlayer()
    private let alarmNotificationManager = AlarmManager()
    private var usesSpatialMix = false
    /// Нет ни spatial-микса, ни одиночного sleep-аудио — только таймер (пользователь не добавил звуки на круг).
    private var sleepSessionSilentNoPlayback = false

    private static let savedAlarmSoundKey = "smartAlarm.selectedSound"

    private static let persistSleepActiveKey = "sleepSession.persist.active"
    private static let persistSleepStartKey = "sleepSession.persist.start"
    private static let persistSleepTimerMinutesKey = "sleepSession.persist.timerMinutes"
    /// Нет звуков на платформе — сессия без фонового саундскейпа (только таймер).
    private static let persistSleepNoSoundscapeKey = "sleepSession.persist.noSoundscape"

    /// Sounds placed on the spatial platform (Step 2). Empty => legacy single-sound path.
    @Published var spatialPlacedSounds: [SpatialPlacedSound] = []

    private var countdownTask: Task<Void, Never>?
    /// Пока идёт сон с фоновым аудио — опрашиваем pending-уведомление, чтобы в момент будильника запустить тот же путь, что и Sleepzy (`applicationMusicPlayer`), с выключенным экраном.
    private var morningWakeMonitorTask: Task<Void, Never>?
    private var sessionStartDate: Date?
    private var didFinishSession = false
    /// UIApplication + AVAudioSession observers (lock screen, multitasking, headphones, interruptions).
    private var notificationObservers: [NSObjectProtocol] = []
    /// Периодически поднимает сессию и play() — iOS иногда глушит фон без явной паузы.
    private var sleepAudioWatchdog: Timer?
    /// Пока звонит будильник — поднимаем AVAudioPlayer / Apple Music.
    private var alarmRingWatchdog: Timer?
    /// Сколько раз нажали Snooze в текущей серии звонков (сброс при «I'm awake» и новом Go to Sleep).
    @Published private(set) var snoozeCountForCurrentRing: Int = 0

    init(audioManager: AudioManager = AudioManager()) {
        self.audioManager = audioManager
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        notificationObservers = [
            nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] n in
                guard let self else { return }
                Task { @MainActor in self.handleAudioInterruption(n) }
            },
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.handleAppDidEnterBackground() }
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.handleAppWillEnterForeground() }
            },
            nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] n in
                guard let self else { return }
                Task { @MainActor in self.handleRouteChange(n) }
            },
            nc.addObserver(forName: .sleepPlaybackRemotePlay, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.tickSleepAudioWatchdog() }
            },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.syncStateAfterAppActivation() }
            }
        ]
        restorePersistedSleepSessionIfNeeded()
    }

    deinit {
        morningWakeMonitorTask?.cancel()
        sleepAudioWatchdog?.invalidate()
        alarmRingWatchdog?.invalidate()
        for o in notificationObservers {
            NotificationCenter.default.removeObserver(o)
        }
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

    /// Превью до сна или живое обновление микса, пока идёт таймер сна (тот же экран, что шаг 2).
    func syncSpatialPreview() {
        if isRunning {
            guard sleepUIMode == .sleeping else { return }
            applyLiveSpatialMixWhileSleeping()
            return
        }
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

    /// Один код-путь со `startSleep()` при непустом spatial: надёжнее, чем отдельный `AudioManager.startSleep` с тихого таймера.
    private func applyLiveSpatialMixWhileSleeping() {
        if spatialPlacedSounds.isEmpty {
            spatialMixer.stop()
            usesSpatialMix = false
            sleepSessionSilentNoPlayback = true
            publishSleepNowPlayingIfRunning()
            persistSleepSessionState()
            return
        }
        if !usesSpatialMix, !sleepSessionSilentNoPlayback {
            audioManager.stopPlaybackSilently()
        }
        sleepSessionSilentNoPlayback = false
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
        publishSleepNowPlayingIfRunning()
        persistSleepSessionState()
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
        guard !spatialPlacedSounds.isEmpty else { return }
        if isRunning, !usesSpatialMix { return }
        spatialMixer.updateGlobalEffects(
            softness: Float(softness),
            space: Float(space),
            brainFrequencyHz: Float(brainFrequencyHz)
        )
    }

    /// Only rebalance volumes while dragging nodes (no engine restart).
    func updateSpatialMixVolumes() {
        guard !isRunning || sleepUIMode == .sleeping else { return }
        let vols = SpatialPlacedSound.normalizedVolumes(for: spatialPlacedSounds)
        spatialMixer.updateVolumes(vols)
    }

    /// Live volume preview while dragging — uses temporary offsets without publishing every frame.
    func updateSpatialMixVolumesWithOverrides(_ unitOffsetsById: [UUID: CGPoint]) {
        guard !isRunning || sleepUIMode == .sleeping else { return }
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
            return "Silent (timer only)"
        }
        let dominant = dominantSpatialSound()
        let count = spatialPlacedSounds.count
        return count > 1 ? "\(dominant.displayName) · \(count) layers" : dominant.displayName
    }

    private func persistSleepSessionState() {
        guard isRunning, let start = sessionStartDate else { return }
        UserDefaults.standard.set(true, forKey: Self.persistSleepActiveKey)
        UserDefaults.standard.set(start.timeIntervalSince1970, forKey: Self.persistSleepStartKey)
        UserDefaults.standard.set(timerMinutes, forKey: Self.persistSleepTimerMinutesKey)
        UserDefaults.standard.set(sleepSessionSilentNoPlayback, forKey: Self.persistSleepNoSoundscapeKey)
    }

    private static func clearPersistedSleepSessionState() {
        UserDefaults.standard.set(false, forKey: persistSleepActiveKey)
        UserDefaults.standard.removeObject(forKey: persistSleepStartKey)
        UserDefaults.standard.removeObject(forKey: persistSleepTimerMinutesKey)
        UserDefaults.standard.removeObject(forKey: persistSleepNoSoundscapeKey)
    }

    /// После выгрузки приложения восстанавливаем таймер и при необходимости включаем будильник.
    private func restorePersistedSleepSessionIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.persistSleepActiveKey) else { return }
        guard let startTs = UserDefaults.standard.object(forKey: Self.persistSleepStartKey) as? TimeInterval else {
            Self.clearPersistedSleepSessionState()
            return
        }
        let minutes = max(1, UserDefaults.standard.integer(forKey: Self.persistSleepTimerMinutesKey))
        let start = Date(timeIntervalSince1970: startTs)
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        let now = Date()

        if now >= end {
            sessionStartDate = start
            timerMinutes = minutes
            isRunning = true
            didFinishSession = false
            sleepUIMode = .sleeping
            remainingSeconds = 0
            Task { @MainActor in
                self.handleSleepTimerElapsed()
            }
            return
        }

        sessionStartDate = start
        timerMinutes = minutes
        isRunning = true
        didFinishSession = false
        sleepUIMode = .sleeping
        remainingSeconds = max(0, Int(floor(end.timeIntervalSinceNow)))
        startCountdown()
        Task { [weak self] in
            guard let self else { return }
            await AlarmLocalFileStorage.ensureNotifyExportIfNeeded()
            let sound = Self.loadSavedAlarmSound()
            try? await self.alarmNotificationManager.scheduleSleepTimerEndNotification(
                secondsFromNow: max(5, Int(ceil(end.timeIntervalSinceNow))),
                sound: sound
            )
        }
        Task { @MainActor in
            self.resumeSleepAudioAfterRestoreIfNeeded()
        }
    }

    private func resumeSleepAudioAfterRestoreIfNeeded() {
        guard isRunning, sleepUIMode == .sleeping else { return }
        sleepSessionSilentNoPlayback = UserDefaults.standard.bool(forKey: Self.persistSleepNoSoundscapeKey)
        if sleepSessionSilentNoPlayback {
            usesSpatialMix = false
            publishSleepNowPlayingIfRunning()
            startSleepAudioWatchdog()
            startMorningWakeMonitorIfNeeded()
            return
        }
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
        } else {
            usesSpatialMix = false
            let remainingMin = max(1, (remainingSeconds + 59) / 60)
            let sound = selectedSound
            let volume = Float(self.volume)
            let softness = Float(self.softness)
            let space = Float(self.space)
            Task { [weak self] in
                guard let self else { return }
                await self.audioManager.startSleep(
                    sound: sound,
                    volume: volume,
                    softness: softness,
                    space: space,
                    brainFrequencyHz: Float(self.brainFrequencyHz),
                    durationMinutes: remainingMin
                ) { }
            }
        }
        publishSleepNowPlayingIfRunning()
        startSleepAudioWatchdog()
        startMorningWakeMonitorIfNeeded()
    }

    func startSleep() {
        guard !isRunning else { return }
        snoozeCountForCurrentRing = 0
        isRunning = true
        sleepUIMode = .sleeping
        didFinishSession = false
        sessionStartDate = Date()
        remainingSeconds = max(0, timerMinutes * 60)
        scheduleSleepEndNotificationIfPossible()
        startCountdown()
        startSleepAudioWatchdog()
        startMorningWakeMonitorIfNeeded()

        if !spatialPlacedSounds.isEmpty {
            sleepSessionSilentNoPlayback = false
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
            publishSleepNowPlayingIfRunning()
            persistSleepSessionState()
            return
        }

        sleepSessionSilentNoPlayback = true
        usesSpatialMix = false
        publishSleepNowPlayingIfRunning()
        persistSleepSessionState()
    }

    func stopSleep() {
        guard isRunning else { return }
        if sleepUIMode == .alarmRinging {
            dismissAlarmAndFinish()
            return
        }
        alarmNotificationManager.cancelSleepTimerNotification()
        AudioManager.clearSleepNowPlaying()
        if usesSpatialMix {
            spatialMixer.stop()
            usesSpatialMix = false
        } else if !sleepSessionSilentNoPlayback {
            audioManager.stopSleep()
        }
        sleepSessionSilentNoPlayback = false
        finishSession(stoppedEarly: true)
    }

    /// Пользователь выключил будильник после окончания таймера.
    func dismissAlarmAndFinish() {
        guard isRunning, sleepUIMode == .alarmRinging else { return }
        snoozeCountForCurrentRing = 0
        alarmRingPlayer.stop()
        AlarmPlaybackAnchor.clear()
        alarmNotificationManager.cancelSleepTimerNotification()
        // Снять основной + все отложенные «Alarm reminder N», иначе через пару минут снова прилетит уведомление.
        alarmNotificationManager.cancelScheduledMorningAlarm()
        NotificationCenter.default.post(name: .userDismissedMorningAlarm, object: nil)
        sleepUIMode = .sleeping
        finishSession(stoppedEarly: false)
    }

    var canSnoozeFromAlarm: Bool {
        guard AlarmBehaviorSettings.isSnoozeEnabled else { return false }
        let maxC = AlarmBehaviorSettings.snoozeMaxCount
        if maxC == 0 { return true }
        return snoozeCountForCurrentRing < maxC
    }

    /// Отложить на интервал из настроек; снова в режим сна до следующего уведомления.
    func snoozeFromAlarm() async {
        guard isRunning, sleepUIMode == .alarmRinging else { return }
        guard canSnoozeFromAlarm else { return }
        let minutes = AlarmBehaviorSettings.snoozeIntervalMinutes
        let sound = Self.loadSavedAlarmSound()
        do {
            try await alarmNotificationManager.scheduleSnoozeNotification(minutesFromNow: minutes, sound: sound)
        } catch {
            return
        }
        snoozeCountForCurrentRing += 1
        stopAlarmRingWatchdog()
        alarmRingPlayer.stop()
        sleepUIMode = .sleeping
        startMorningWakeMonitorIfNeeded()
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
        guard !sleepSessionSilentNoPlayback else { return }
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

    private func startMorningWakeMonitorIfNeeded() {
        morningWakeMonitorTask?.cancel()
        morningWakeMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let stillSleeping = await MainActor.run {
                    self.isRunning && self.sleepUIMode == .sleeping
                }
                guard stillSleeping else { return }
                guard let fireDate = await self.alarmNotificationManager.nextScheduledAlarmFireDate() else { continue }
                let shouldRing = await MainActor.run {
                    self.isRunning && self.sleepUIMode == .sleeping && Date() >= fireDate.addingTimeInterval(-1.5)
                }
                guard shouldRing else { continue }
                await MainActor.run {
                    guard self.isRunning, self.sleepUIMode == .sleeping else { return }
                    self.handleExternalAlarmFired()
                }
            }
        }
    }

    private func stopMorningWakeMonitor() {
        morningWakeMonitorTask?.cancel()
        morningWakeMonitorTask = nil
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRunning && self.sleepUIMode == .sleeping && self.remainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.remainingSeconds = max(0, self.remainingSeconds - 1)
            }
            guard self.isRunning, !Task.isCancelled else { return }
            guard self.sleepUIMode == .sleeping else { return }
            await MainActor.run {
                self.handleSleepTimerElapsed()
            }
        }
    }

    private func handleSleepTimerElapsed() {
        guard isRunning, sleepUIMode == .sleeping else { return }
        if usesSpatialMix {
            spatialMixer.stop()
            usesSpatialMix = false
        } else if !sleepSessionSilentNoPlayback {
            audioManager.stopPlaybackSilently()
        }
        sleepSessionSilentNoPlayback = false
        // Таймер засыпания завершает сессию тихо: останавливаем «сон» без запуска утреннего будильника.
        alarmNotificationManager.cancelSleepTimerNotification()
        finishSession(stoppedEarly: false)
    }

    /// - `usePlaybackAnchor`: `false` для окончания таймера сна в приложении (начать с нуля); `true` если сработал системный будильник/уведомление.
    private func beginAlarmRinging(usePlaybackAnchor: Bool) {
        guard sleepUIMode != .alarmRinging else { return }
        alarmNotificationManager.clearWakeRemindersAfterInAppAlarmHandling()
        stopMorningWakeMonitor()
        stopSleepAudioWatchdog()
        alarmNotificationManager.cancelSleepTimerNotification()
        AudioManager.clearSleepNowPlaying()
        let option = Self.loadSavedAlarmSound()
        sleepUIMode = .alarmRinging
        alarmRingPlayer.start(option: option, usePlaybackAnchor: usePlaybackAnchor)
        startAlarmRingWatchdog()
    }

    /// Called when system notification alarm fires while Sleep Mode is open.
    func handleExternalAlarmFired() {
        guard isRunning else { return }
        guard sleepUIMode == .sleeping else { return }
        if usesSpatialMix {
            spatialMixer.stop()
            usesSpatialMix = false
        } else if !sleepSessionSilentNoPlayback {
            audioManager.stopPlaybackSilently()
        }
        sleepSessionSilentNoPlayback = false
        beginAlarmRinging(usePlaybackAnchor: true)
    }

    private static func loadSavedAlarmSound() -> AlarmSoundOption {
        guard let raw = UserDefaults.standard.string(forKey: savedAlarmSoundKey) else {
            return .mechDigitalBuzzer
        }
        return AlarmSoundOption.migrated(from: raw) ?? .mechDigitalBuzzer
    }

    private func scheduleSleepEndNotificationIfPossible() {
        let sec = max(0, timerMinutes * 60)
        guard sec > 0 else { return }
        let sound = Self.loadSavedAlarmSound()
        Task {
            await AlarmLocalFileStorage.ensureNotifyExportIfNeeded()
            try? await alarmNotificationManager.scheduleSleepTimerEndNotification(
                secondsFromNow: sec,
                sound: sound
            )
        }
    }

    private func finishSession(stoppedEarly: Bool) {
        guard !didFinishSession else { return }
        didFinishSession = true
        sleepSessionSilentNoPlayback = false
        Self.clearPersistedSleepSessionState()
        stopMorningWakeMonitor()
        stopSleepAudioWatchdog()
        stopAlarmRingWatchdog()
        AudioManager.clearSleepNowPlaying()
        alarmRingPlayer.stop()
        AlarmPlaybackAnchor.clear()
        sleepUIMode = .sleeping
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

    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard isRunning else { return }
        switch phase {
        case .active:
            syncStateAfterAppActivation()
        case .inactive, .background:
            if sleepUIMode == .sleeping {
                reassertSleepAudioAfterBackgroundEvent()
                applySoundSettingsIfRunning()
            } else if sleepUIMode == .alarmRinging {
                alarmRingPlayer.reassertAlarmPlaybackIfNeeded()
            }
        @unknown default:
            break
        }
    }

    /// Синхронизация таймера/UI и аудио при возврате в приложение (разблокировка, смена приложения).
    func syncSleepUIWhenViewAppears() {
        syncStateAfterAppActivation()
    }

    private func syncStateAfterAppActivation() {
        guard isRunning else { return }
        refreshRemainingSecondsFromWallClock()
        if sleepUIMode == .sleeping {
            reassertSleepAudioAfterBackgroundEvent()
            publishSleepNowPlayingIfRunning()
            applySoundSettingsIfRunning()
        } else if sleepUIMode == .alarmRinging {
            alarmRingPlayer.reassertAlarmPlaybackIfNeeded()
        }
    }

    /// Возврат в приложение без тапа по баннеру — восстановить полный звук будильника в режиме сна.
    func reassertAlarmPlaybackFromForegroundIfNeeded() {
        guard isRunning, sleepUIMode == .alarmRinging else { return }
        alarmRingPlayer.reassertAlarmPlaybackIfNeeded()
    }

    private func publishSleepNowPlayingIfRunning() {
        guard isRunning else { return }
        if sleepSessionSilentNoPlayback {
            AudioManager.publishSleepNowPlaying(title: "Sleep", subtitle: "Timer only — no soundscape")
        } else {
            AudioManager.publishSleepNowPlaying(title: "Sleep mix", subtitle: mixSummaryLabel())
        }
    }

    private func startSleepAudioWatchdog() {
        sleepAudioWatchdog?.invalidate()
        sleepAudioWatchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickSleepAudioWatchdog()
            }
        }
        if let t = sleepAudioWatchdog {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func stopSleepAudioWatchdog() {
        sleepAudioWatchdog?.invalidate()
        sleepAudioWatchdog = nil
    }

    private func startAlarmRingWatchdog() {
        alarmRingWatchdog?.invalidate()
        alarmRingWatchdog = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickAlarmRingWatchdog()
            }
        }
        if let t = alarmRingWatchdog {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    private func stopAlarmRingWatchdog() {
        alarmRingWatchdog?.invalidate()
        alarmRingWatchdog = nil
    }

    private func tickAlarmRingWatchdog() {
        guard isRunning, sleepUIMode == .alarmRinging else { return }
        alarmRingPlayer.reassertAlarmPlaybackIfNeeded()
    }

    private func tickSleepAudioWatchdog() {
        guard isRunning, sleepUIMode == .sleeping else { return }
        guard !sleepSessionSilentNoPlayback else { return }
        try? AudioManager.configureSleepPlaybackSession()
        if usesSpatialMix {
            spatialMixer.reassertPlaybackIfNeeded()
        } else {
            audioManager.reassertSleepPlaybackIfNeeded()
        }
        publishSleepNowPlayingIfRunning()
    }

    private func reassertSleepAudioAfterBackgroundEvent() {
        guard isRunning, sleepUIMode == .sleeping else { return }
        guard !sleepSessionSilentNoPlayback else { return }
        if usesSpatialMix {
            spatialMixer.reassertPlaybackIfNeeded()
        } else {
            audioManager.reassertSleepPlaybackIfNeeded()
        }
    }

    private func refreshRemainingSecondsFromWallClock() {
        guard sleepUIMode == .sleeping, let start = sessionStartDate else { return }
        let totalSec = max(0, timerMinutes * 60)
        let end = start.addingTimeInterval(TimeInterval(totalSec))
        let left = max(0, Int(floor(end.timeIntervalSinceNow)))
        remainingSeconds = left
        // Сравнение по Date надёжнее, чем left == 0 (нет «залипания» на 1 с из-за округления).
        if Date() >= end, isRunning, sleepUIMode == .sleeping {
            handleSleepTimerElapsed()
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.sleepTimerEndNotificationId])
        }
    }

    private static let sleepTimerEndNotificationId = "smart_alarm_sleep_timer_end"

    private func handleAudioInterruption(_ notification: Notification) {
        guard isRunning else { return }
        guard let info = notification.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let intType = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        if intType == .ended {
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                if sleepUIMode == .sleeping {
                    reassertSleepAudioAfterBackgroundEvent()
                    publishSleepNowPlayingIfRunning()
                } else if sleepUIMode == .alarmRinging {
                    alarmRingPlayer.reassertAlarmPlaybackIfNeeded()
                }
            }
        }
    }

    /// Home / lock / другие приложения — дублирует ScenePhase, но ловит кейсы, где сцена не шлёт событие.
    private func handleAppDidEnterBackground() {
        guard isRunning else { return }
        if sleepUIMode == .sleeping {
            reassertSleepAudioAfterBackgroundEvent()
            publishSleepNowPlayingIfRunning()
        } else if sleepUIMode == .alarmRinging {
            alarmRingPlayer.reassertAlarmPlaybackIfNeeded()
        }
    }

    private func handleAppWillEnterForeground() {
        syncStateAfterAppActivation()
    }

    /// Наушники, Bluetooth, динамик — переподключение может остановить плеер без смены сцены.
    private func handleRouteChange(_: Notification) {
        guard isRunning else { return }
        if sleepUIMode == .sleeping {
            reassertSleepAudioAfterBackgroundEvent()
            publishSleepNowPlayingIfRunning()
        } else if sleepUIMode == .alarmRinging {
            alarmRingPlayer.reassertAlarmPlaybackIfNeeded()
        }
    }
}

