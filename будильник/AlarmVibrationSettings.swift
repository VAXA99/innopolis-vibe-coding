import Foundation

#if canImport(UIKit) && os(iOS)
import AudioToolbox
import UIKit
#endif

// MARK: - Типичные настройки будильников (референс для продукта)
//
// Часто встречаются блоки:
// • Время / повтор дней недели
// • Звук мелодии, громкость, постепенное увеличение (crescendo)
// • Вибрация: вкл/выкл, рисунок, интервал или «по умолчанию»
// • Отложить (snooze): длительность, лимит раз, интервал
// • Название будильника, ярлык
// • Умное окно / «не будить в глубоком сне» (если заявлено)
// • Связь с особыми режимами (Фокус, выходные)
//
// У нас уже есть: звук (шаг 1), Smart Wake, вибрация. Нет: snooze по дням, crescendo, громкость отдельно.
// Ниже — расширенная вибрация + каркас секций в листе настроек.

/// Настройки вибрации, пока звенит будильник (не телефонный звонок).
enum AlarmVibrationSettings {
    private static let enabledKey = "alarm.vibration.enabled"
    private static let intervalKey = "alarm.vibration.intervalSeconds"
    private static let styleKey = "alarm.vibration.style"
    private static let modeKey = "alarm.vibration.mode"
    private static let patternJSONKey = "alarm.vibration.customPatternJSON"
    private static let patternGapKey = "alarm.vibration.patternRepeatGapSeconds"

    enum Mode: String, CaseIterable, Identifiable {
        case standard
        case customPattern

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: return "Стандарт"
            case .customPattern: return "Свой рисунок"
            }
        }
    }

    enum Style: String, CaseIterable, Identifiable {
        case gentle
        case strong
        case both

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gentle: return "Мягкая (Taptic)"
            case .strong: return "Системная"
            case .both: return "Обе"
            }
        }
    }

    /// Один сэмпл записанного рисунка (время от начала записи, сила удара, системный buzz).
    struct PatternSample: Codable, Equatable, Identifiable {
        var offset: TimeInterval
        var intensity: Float
        var systemBuzz: Bool

        var id: String { String(format: "%.4f_%.2f", offset, intensity) }

        init(offset: TimeInterval, intensity: Float, systemBuzz: Bool) {
            self.offset = offset
            self.intensity = min(1, max(0.05, intensity))
            self.systemBuzz = systemBuzz
        }
    }

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var mode: Mode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modeKey),
                  let m = Mode(rawValue: raw) else { return .standard }
            return m
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// В режиме standard — пауза между одинаковыми импульсами.
    static var pulseIntervalSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: intervalKey)
            if v < 0.35 { return 2.5 }
            return min(6.0, max(0.8, v))
        }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }

    /// В режиме custom — пауза после окончания рисунка до следующего повтора цикла.
    static var patternRepeatGapSeconds: Double {
        get {
            let v = UserDefaults.standard.double(forKey: patternGapKey)
            if v < 0.2 { return 2.0 }
            return min(8.0, max(0.5, v))
        }
        set { UserDefaults.standard.set(newValue, forKey: patternGapKey) }
    }

    static var style: Style {
        get {
            guard let raw = UserDefaults.standard.string(forKey: styleKey),
                  let s = Style(rawValue: raw) else { return .both }
            return s
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    /// Всегда включаем системную вибрацию вместе с Taptic в своём рисунке (отдельный переключатель убран из интерфейса).
    static var customPatternMixSystemBuzz: Bool {
        get { true }
        set { _ = newValue }
    }

    static func loadCustomPattern() -> [PatternSample] {
        guard let data = UserDefaults.standard.data(forKey: patternJSONKey),
              let decoded = try? JSONDecoder().decode([PatternSample].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.offset < $1.offset }
    }

    static func saveCustomPattern(_ samples: [PatternSample]) {
        let sorted = samples.sorted { $0.offset < $1.offset }
        let withSystemBuzz = sorted.map { PatternSample(offset: $0.offset, intensity: $0.intensity, systemBuzz: true) }
        if let data = try? JSONEncoder().encode(withSystemBuzz) {
            UserDefaults.standard.set(data, forKey: patternJSONKey)
        }
    }

    /// Сдвигает таймлайн к нулю (после остановки записи или перед сохранением).
    static func normalizeCustomPatternTimeline(_ samples: [PatternSample]) -> [PatternSample] {
        guard let first = samples.map(\.offset).min() else { return samples }
        return samples.map { PatternSample(offset: max(0, $0.offset - first), intensity: $0.intensity, systemBuzz: true) }
    }

    static func clearCustomPattern() {
        UserDefaults.standard.removeObject(forKey: patternJSONKey)
    }

#if canImport(UIKit) && os(iOS)
    @MainActor
    static func playStandardSamplePulse() {
        guard isEnabled else { return }
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        switch style {
        case .gentle:
            gen.impactOccurred(intensity: 0.72)
        case .strong:
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        case .both:
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            gen.impactOccurred(intensity: 0.55)
        }
    }

    /// Один проигрыш записанного рисунка (предпросмотр). Не зависит от «вибрация вкл» — пользователь явно нажал «прослушать».
    @MainActor
    static func playCustomPatternPreview(samples: [PatternSample]) {
        guard !samples.isEmpty else { return }
        CustomPatternPreviewPlayer.shared.play(samples: samples)
    }
#endif
}

#if canImport(UIKit) && os(iOS)
/// Удерживает `UIImpactFeedbackGenerator`, пока не отработают отложенные импульсы (иначе предпросмотр часто «молчит»).
@MainActor
private final class CustomPatternPreviewPlayer {
    static let shared = CustomPatternPreviewPlayer()

    private let generator = UIImpactFeedbackGenerator(style: .heavy)
    private var retainToken: CustomPatternPreviewPlayer?

    func play(samples: [AlarmVibrationSettings.PatternSample]) {
        retainToken = self
        generator.prepare()
        let maxOffset = samples.map(\.offset).max() ?? 0
        for s in samples {
            DispatchQueue.main.asyncAfter(deadline: .now() + s.offset) { [generator] in
                if s.systemBuzz {
                    AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                }
                generator.impactOccurred(intensity: CGFloat(s.intensity))
                generator.prepare()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + maxOffset + 0.45) { [weak self] in
            self?.retainToken = nil
        }
    }
}
#endif
