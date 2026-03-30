import Foundation

/// Five loop assets shipped in the app bundle (`*.mp3` in target).
enum SleepSound: String, CaseIterable, Identifiable, Hashable {
    case rain
    case fire
    case softPad
    case brook
    case cosmicDream

    var id: String { rawValue }

    static let allCases: [SleepSound] = [.rain, .fire, .softPad, .brook, .cosmicDream]

    var displayName: String {
        switch self {
        case .rain: return "Rain"
        case .fire: return "Bells"
        case .softPad: return "Vocal"
        case .brook: return "Water"
        case .cosmicDream: return "Plane"
        }
    }

    var iconName: String {
        switch self {
        case .rain: return "cloud.rain.fill"
        case .fire: return "bell.fill"
        case .softPad: return "person.wave.2.fill"
        case .brook: return "water.waves"
        case .cosmicDream: return "airplane"
        }
    }

    var fileResourceName: String {
        switch self {
        case .rain: return "rain_ambience"
        case .fire: return "fire_loop"
        case .softPad: return "air_cabin"
        case .brook: return "brook_murmur"
        case .cosmicDream: return "cosmic_dream"
        }
    }

    var fileExtension: String { "mp3" }

    struct DividerWaveProfile: Equatable {
        let baseAmplitude: Double
        let speed: Double
        let roughness: Double
        let glow: Double
        let motionA: Double
        let motionB: Double
        let signature: Double
    }

    /// Поведение фиолетовой волны-разделителя по характеру звука.
    var dividerWaveProfile: DividerWaveProfile {
        switch self {
        case .rain:
            return DividerWaveProfile(baseAmplitude: 0.24, speed: 0.88, roughness: 0.18, glow: 0.32, motionA: 0.72, motionB: 0.96, signature: 0.22)
        case .brook:
            return DividerWaveProfile(baseAmplitude: 0.30, speed: 0.98, roughness: 0.24, glow: 0.36, motionA: 1.02, motionB: 0.84, signature: 0.46)
        case .softPad:
            return DividerWaveProfile(baseAmplitude: 0.19, speed: 0.72, roughness: 0.10, glow: 0.27, motionA: 0.56, motionB: 0.68, signature: 0.08)
        case .cosmicDream:
            return DividerWaveProfile(baseAmplitude: 0.36, speed: 1.14, roughness: 0.32, glow: 0.42, motionA: 1.28, motionB: 1.46, signature: 0.72)
        case .fire:
            return DividerWaveProfile(baseAmplitude: 0.17, speed: 0.76, roughness: 0.12, glow: 0.25, motionA: 0.44, motionB: 0.60, signature: 0.90)
        }
    }

    /// Индивидуальный кроссфейд на шве лупа: подбираем по типу материала.
    var loopCrossfadeDuration: TimeInterval {
        switch self {
        case .rain: return 2.0
        case .brook: return 1.8
        case .softPad: return 1.6
        case .cosmicDream: return 1.4
        case .fire: return 1.0
        }
    }

    var resourceURL: URL? {
        Bundle.main.url(forResource: fileResourceName, withExtension: fileExtension)
    }
}
