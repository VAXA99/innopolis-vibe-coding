import SwiftUI
import Foundation
import Combine

@MainActor
final class SleepViewModel: ObservableObject {
    @Published var selectedSound: SleepSound = .rain

    // 0...1 sliders
    @Published var volume: Double = 0.75
    @Published var softness: Double = 0.35
    @Published var space: Double = 0.55

    @Published var timerMinutes: Int = 15
    @Published var isRunning: Bool = false

    private let audioManager: AudioManager

    init(audioManager: AudioManager = AudioManager()) {
        self.audioManager = audioManager
    }

    func startSleep() {
        guard !isRunning else { return }
        isRunning = true

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
                durationMinutes: durationMinutes
            ) { [weak self] in
                Task { @MainActor in
                    self?.isRunning = false
                }
            }
        }
    }

    func stopSleep() {
        guard isRunning else { return }
        isRunning = false
        audioManager.stopSleep()
    }

    func applySoundSettingsIfRunning() {
        guard isRunning else { return }
        audioManager.applySoundSettings(
            volume: Float(volume),
            softness: Float(softness),
            space: Float(space)
        )
    }
}

