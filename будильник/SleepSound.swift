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

    var resourceURL: URL? {
        Bundle.main.url(forResource: fileResourceName, withExtension: fileExtension)
    }
}
