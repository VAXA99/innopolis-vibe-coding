import Foundation

enum SleepSound: String, CaseIterable, Identifiable, Hashable {
    case rain
    case forest
    case fire
    case ocean
    case whiteNoise
    case brownNoise

    var id: String { rawValue }

    static let allCases: [SleepSound] = [.rain, .forest, .fire, .ocean, .whiteNoise, .brownNoise]

    var displayName: String {
        switch self {
        case .rain: return "Rain"
        case .forest: return "Forest Night"
        case .fire: return "Campfire"
        case .ocean: return "Ocean Waves"
        case .whiteNoise: return "White Noise"
        case .brownNoise: return "Brown Noise"
        }
    }

    var iconName: String {
        switch self {
        case .rain: return "cloud.rain.fill"
        case .forest: return "leaf.fill"
        case .fire: return "flame.fill"
        case .ocean: return "wave.3.right.circle.fill"
        case .whiteNoise: return "circle.grid.cross.fill"
        case .brownNoise: return "circle.grid.3x3.fill"
        }
    }

    // These should exist inside the app bundle (add the actual files to Xcode).
    var fileResourceName: String {
        switch self {
        case .rain: return "rain_on_window"
        case .forest: return "forest_night"
        case .fire: return "campfire"
        case .ocean: return "ocean_waves"
        case .whiteNoise: return "white_noise"
        case .brownNoise: return "brown_noise"
        }
    }

    var fileExtension: String {
        switch self {
        case .whiteNoise, .brownNoise: return "wav"
        default: return "mp3"
        }
    }

    var resourceURL: URL? {
        Bundle.main.url(forResource: fileResourceName, withExtension: fileExtension)
    }
}

