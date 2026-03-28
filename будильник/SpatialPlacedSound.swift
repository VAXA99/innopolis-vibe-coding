import Foundation
import CoreGraphics

/// Sound token on the circular platform. `unitOffset` is in normalized coordinates:
/// center = (0,0), edge of circle = magnitude 1.
struct SpatialPlacedSound: Identifiable, Equatable {
    let id: UUID
    var sound: SleepSound
    var unitOffset: CGPoint

    init(id: UUID = UUID(), sound: SleepSound, unitOffset: CGPoint) {
        self.id = id
        self.sound = sound
        self.unitOffset = Self.clampedToUnitCircle(unitOffset)
    }

    static func clampedToUnitCircle(_ p: CGPoint) -> CGPoint {
        let m = hypot(p.x, p.y)
        guard m > 1, m > 0 else { return p }
        return CGPoint(x: p.x / m, y: p.y / m)
    }

    /// Raw dominance: 1 at center, ~0 at edge; outside unit circle => 0 (drag preview).
    func radialGain() -> Double {
        let d = hypot(unitOffset.x, unitOffset.y)
        if d > 1.0 { return 0 }
        return max(0.05, 1.0 - d)
    }

    static func normalizedVolumes(for placed: [SpatialPlacedSound]) -> [UUID: Float] {
        guard !placed.isEmpty else { return [:] }
        let raw = placed.map { ($0.id, $0.radialGain()) }
        let sum = raw.map(\.1).reduce(0, +)
        if sum <= 0 {
            return Dictionary(uniqueKeysWithValues: raw.map { ($0.0, Float(0)) })
        }
        return Dictionary(uniqueKeysWithValues: raw.map { ($0.0, Float(($0.1 / sum) * 0.92)) })
    }
}
