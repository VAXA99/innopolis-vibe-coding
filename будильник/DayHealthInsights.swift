import Combine
import Foundation
import SwiftUI
#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

struct DayHealthSummary: Sendable, Equatable {
    var stepsToday: Int?
    var activeEnergyKcal: Double?
    var sleepLastNightHours: Double?
    /// До «границы сна» (см. `analyticsDayCutoffHour`) шаги/ккал — вчера 00:00…сейчас, не только «сегодня с полуночи».
    var stepsAndEnergyAreNightExtendedSlice: Bool = false
}

struct DayHealthDailyRecord: Sendable, Equatable, Codable, Identifiable {
    var id: String { dateISO }
    let dateISO: String
    var steps: Int?
    var activeEnergyKcal: Double?
    var sleepHours: Double?
}

enum DayHealthTipBuilder {
    static func tips(from summary: DayHealthSummary?) -> String {
        guard let summary else {
            return "Добавьте данные за сегодня, чтобы увидеть короткую подсказку к вечеру."
        }
        if let sleep = summary.sleepLastNightHours, sleep < 6.5 {
            return "Сон прошлой ночью короткий (~\(String(format: "%.1f", sleep)) ч). Сегодня лучше не тянуть отбой и снизить кофеин вечером."
        }
        if summary.stepsAndEnergyAreNightExtendedSlice, let s = summary.stepsToday, s < 4000 {
            return "Сейчас (до границы в настройках дня) шаги/ккал = вчера + сегодня с полуночи, поэтому «мало шагов» в 1–3 ночи с одной только полуночи в Health не совпадает — смотрите цифру вместе с вчера. Днём цифры снова как в «Сегодня» в Health."
        }
        if let steps = summary.stepsToday, steps < 4000, !summary.stepsAndEnergyAreNightExtendedSlice {
            return "Мало шагов сегодня — добавьте 10–15 минут прогулки до вечера, сон станет глубже."
        }
        if let kcal = summary.activeEnergyKcal, kcal >= 350 {
            return "Хорошая активность (~\(Int(kcal.rounded()))) ккал). Вечером легче «выключиться»."
        }
        return "Показатели в норме — держите стабильный отбой, чтобы завтра проснуться ровнее."
    }

    static func insights(summary: DayHealthSummary?, history: [DayHealthDailyRecord]) -> [String] {
        guard let summary else { return ["Добавьте данные за сегодня, чтобы увидеть персональные инсайты."] }
        var out: [String] = []
        if let sleep = summary.sleepLastNightHours, let steps = summary.stepsToday {
            if sleep < 6.5, steps < 5000 {
                out.append("Мало сна + низкая активность: завтра утром будет тяжелее. Попробуйте лечь хотя бы на 20–30 минут раньше.")
            } else if sleep >= 7.2, steps >= 7000 {
                out.append("Хороший сон и движение: высокий шанс бодрого подъёма без лишнего snooze.")
            }
        }
        let validSleep = history.compactMap(\.sleepHours)
        if validSleep.count >= 3 {
            let avg = validSleep.reduce(0, +) / Double(validSleep.count)
            if avg < 6.8 {
                out.append("Средний сон за \(validSleep.count) дн. = \(String(format: "%.1f", avg)) ч. Это ниже желаемого уровня для стабильной энергии.")
            } else {
                out.append("Средний сон за \(validSleep.count) дн. = \(String(format: "%.1f", avg)) ч. Ритм в целом устойчивый.")
            }
        }
        if let score = recoveryScore(from: summary) {
            if score < 45 {
                out.append("Recovery score \(score)/100: сегодня лучше снизить нагрузку вечером и ускорить отбой.")
            } else if score > 75 {
                out.append("Recovery score \(score)/100: хороший день для стабильного режима без сдвига подъёма.")
            }
        }

        if let sleep = summary.sleepLastNightHours, let kcal = summary.activeEnergyKcal, kcal >= 250 {
            if sleep < 6.5, kcal >= 400 {
                out.append("Короткий сон при заметной активности (~\(Int(kcal.rounded())) ккал): вечером снизьте интенсивность и свет экрана — так проще восстановить сон.")
            }
        }
        if !summary.stepsAndEnergyAreNightExtendedSlice, let sleep = summary.sleepLastNightHours, sleep >= 7, let steps = summary.stepsToday, steps < 3500 {
            out.append("Сон в норме, но шагов мало — дневное движение поддерживает стабильный цикл сон–бодрствование.")
        }
        if !summary.stepsAndEnergyAreNightExtendedSlice, let avg = averageStepsLastDays(history, days: 7), let today = summary.stepsToday {
            let diff = Double(today) - avg
            if abs(diff) >= 800 {
                let dir = diff > 0 ? "выше" : "ниже"
                out.append("Шаги сегодня \(dir) вашего ~7-дневного среднего (\(Int(avg.rounded())) → \(today)): \(diff > 0 ? "нагрузка выше привычного" : "легче обычного дня").")
            }
        }

        out.append(contentsOf: sleepOutlookInsights(summary: summary, history: history))

        return out.isEmpty ? ["Данных пока мало для трендов. Добавьте 3–7 дней Huawei Health."] : out
    }

    /// Простой «прогноз» на ближайшие ночи/утра (не медицина).
    private static func sleepOutlookInsights(summary: DayHealthSummary, history: [DayHealthDailyRecord]) -> [String] {
        var lines: [String] = []
        let last = summary.sleepLastNightHours

        if let h = last {
            if h < 5 {
                lines.append("Сон < 5 ч: завтра выше риск сонливости и просыпания с трудом — заложите +30–45 мин ко сну сегодня.")
            } else if h < 6.5 {
                lines.append("Сон < ~7 ч несколько дней подряд копит «долг сна»: без более раннего отбоя утро будет тяжелее.")
            } else if h >= 7.5 {
                lines.append("Достаточный сон — хорошая база: если сохраните похожее время подъёма, засыпание вечером обычно легче.")
            }
        }

        let sleeps = history.compactMap(\.sleepHours)
        if sleeps.count >= 5 {
            let mean = sleeps.reduce(0, +) / Double(sleeps.count)
            let variance = sleeps.map { pow($0 - mean, 2) }.reduce(0, +) / Double(sleeps.count)
            let stdev = sqrt(variance)
            if stdev > 1.15 {
                lines.append("Сильный разброс длительности сна по дням ломает стабильный циркадный ритм — попробуйте фиксировать время подъёма в ±30 мин.")
            }
        }

        if let steps = summary.stepsToday, let h = last, steps > 10_000, h < 7 {
            lines.append("Много шагов при умеренно коротком сне — нагрузка без полного восстановления; вечером лучше спокойная активность и меньше экрана.")
        }

        return Array(lines.prefix(3))
    }

    private static func averageStepsLastDays(_ history: [DayHealthDailyRecord], days: Int) -> Double? {
        let sorted = history.sorted { $0.dateISO > $1.dateISO }
        let vals = sorted.prefix(days).compactMap(\.steps)
        guard vals.count >= 3 else { return nil }
        return Double(vals.reduce(0, +)) / Double(vals.count)
    }

    private static func recoveryScore(from summary: DayHealthSummary) -> Int? {
        guard let sleep = summary.sleepLastNightHours else { return nil }
        let steps = summary.stepsToday ?? 0
        let energy = summary.activeEnergyKcal ?? 0
        let sleepScore = min(100, max(0, Int((sleep / 8.0) * 50)))
        let moveScore = min(50, max(0, min(100, steps / 120)))
        let bonus = energy > 300 ? 5 : 0
        return min(100, sleepScore + moveScore + bonus)
    }
}

@MainActor
final class DayHealthInsightsStore: ObservableObject {
    enum DataSourceMode: String, CaseIterable, Identifiable {
        case appleHealth
        case huaweiManual
        case huaweiAuto

        var id: String { rawValue }
    }

    enum HealthAuthorizationState: Equatable {
        case unavailable
        case denied
        case shouldRequest
        case unknown
        case sharingAuthorized
    }

    enum HuaweiSourceKind: String, CaseIterable, Identifiable {
        case healthApp
        case watch

        var id: String { rawValue }

        var title: String {
            switch self {
            case .healthApp: return "Huawei Health app"
            case .watch: return "Huawei Watch"
            }
        }

        var subtitle: String {
            switch self {
            case .healthApp: return "Данные из облака Huawei Health"
            case .watch: return "Приоритет данным с часов"
            }
        }
    }

    @Published var dataSourceMode: DataSourceMode {
        didSet { UserDefaults.standard.set(dataSourceMode.rawValue, forKey: Self.modeKey) }
    }

    @Published private(set) var authorizationState: HealthAuthorizationState = .unknown
    @Published private(set) var summary: DayHealthSummary?
    @Published private(set) var isLoading = false
    @Published private(set) var lastErrorMessage: String?

    @Published var huaweiAutoEndpointURL: String {
        didSet { UserDefaults.standard.set(huaweiAutoEndpointURL, forKey: Self.huaweiAutoEndpointKey) }
    }

    @Published var huaweiAutoAccessToken: String {
        didSet { UserDefaults.standard.set(huaweiAutoAccessToken, forKey: Self.huaweiAutoTokenKey) }
    }

    @Published private(set) var lastHuaweiAutoSyncAt: Date? {
        didSet {
            if let lastHuaweiAutoSyncAt {
                UserDefaults.standard.set(lastHuaweiAutoSyncAt.timeIntervalSince1970, forKey: Self.huaweiAutoLastSyncKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.huaweiAutoLastSyncKey)
            }
        }
    }

    @Published var huaweiSourceKind: HuaweiSourceKind {
        didSet { UserDefaults.standard.set(huaweiSourceKind.rawValue, forKey: Self.huaweiSourceKindKey) }
    }

    @Published var huaweiAutoSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(huaweiAutoSyncEnabled, forKey: Self.huaweiAutoSyncEnabledKey) }
    }

    @Published var analyticsDayCutoffHour: Int {
        didSet { UserDefaults.standard.set(analyticsDayCutoffHour, forKey: Self.analyticsDayCutoffHourKey) }
    }

    @Published private(set) var huaweiManualHistory: [DayHealthDailyRecord] = []

    /// `true`, если сервер пометил ответ как демо/заглушку (не живые данные Huawei с аккаунта).
    @Published private(set) var huaweiPayloadIsDemo: Bool = false

    @Published private(set) var renderUploadInProgress = false
    @Published private(set) var lastRenderUploadAt: Date?
    @Published private(set) var lastRenderUploadMessage: String?

    private static let modeKey = "dayHealth.dataSourceMode"
    private static let huaweiAutoEndpointKey = "dayHealth.huaweiAuto.endpoint"
    private static let huaweiAutoTokenKey = "dayHealth.huaweiAuto.token"
    private static let huaweiAutoLastSyncKey = "dayHealth.huaweiAuto.lastSync"
    private static let huaweiSourceKindKey = "dayHealth.huawei.sourceKind"
    private static let huaweiAutoSyncEnabledKey = "dayHealth.huawei.autoSyncEnabled"
    private static let analyticsDayCutoffHourKey = "dayHealth.analytics.cutoffHour"
    private static let huaweiHistoryKey = "dayHealth.huawei.history.json"
    private static let renderDeviceIdKey = "dayHealth.renderDeviceId"
    /// `true` после `requestAuthorization` — iOS нередко не переводит read-доступ в `sharingAuthorized`, оставляя `notDetermined`.
    private static let hasRequestedHealthReadKey = "dayHealth.appleHealthReadRequested"

    /// Ensures `https` and `/v1/huawei/summary` when the user pastes only the Render host.
    private static func normalizedHuaweiEndpointString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var s = trimmed
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard var comp = URLComponents(string: s) else { return trimmed }
        let path = comp.path
        if path.isEmpty || path == "/" {
            comp.path = "/v1/huawei/summary"
        }
        return comp.url?.absoluteString ?? trimmed
    }

    /// POST `/v1/health/daily-upload` на том же хосте, что и Huawei summary (например Render).
    func renderHealthDailyUploadURL() -> URL? {
        let normalized = Self.normalizedHuaweiEndpointString(huaweiAutoEndpointURL)
        guard var comp = URLComponents(string: normalized) else { return nil }
        comp.path = "/v1/health/daily-upload"
        comp.query = nil
        comp.fragment = nil
        return comp.url
    }

    private var stableRenderDeviceId: String {
        let ud = UserDefaults.standard
        if let s = ud.string(forKey: Self.renderDeviceIdKey), !s.isEmpty { return s }
        let id = UUID().uuidString
        ud.set(id, forKey: Self.renderDeviceIdKey)
        return id
    }

    #if os(iOS) && canImport(HealthKit)
    private let healthStore = HKHealthStore()
    #endif

    var isHealthDataAvailable: Bool {
        #if os(iOS) && canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    /// Все поля `nil` — запросы не вернули значения (пусто в Health или нет доступа к категориям).
    var appleHealthSummaryHasNoValues: Bool {
        guard dataSourceMode == .appleHealth, let s = summary else { return false }
        return s.stepsToday == nil && s.activeEnergyKcal == nil && s.sleepLastNightHours == nil
    }

    var isHuaweiAutoConfigured: Bool {
        let u = huaweiAutoEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = huaweiAutoAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return !u.isEmpty && !t.isEmpty
    }

    var huaweiAutoHostLabel: String {
        let s = huaweiAutoEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let host = url.host else {
            return s.isEmpty ? "—" : s
        }
        return host
    }

    var isHuaweiAutoDataStale: Bool {
        guard isHuaweiAutoConfigured else { return false }
        guard let last = lastHuaweiAutoSyncAt else { return true }
        return Date().timeIntervalSince(last) > 6 * 3600
    }

    /// До `analyticsDayCutoffHour` (0…6) шаги/ккал считаем с полуночи **вчера** = календарный **вчера** + **сегодня** с 0:00 (суммарно, без «только 2 ночи как сегодня»).
    var isInNightExtendedActivityWindow: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        let cut = min(6, max(0, analyticsDayCutoffHour))
        return h < cut
    }

    var startOfStepsOrEnergyQueryInterval: Date {
        let cal = Calendar.current
        let now = Date()
        if isInNightExtendedActivityWindow {
            return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)) ?? cal.startOfDay(for: now)
        }
        return cal.startOfDay(for: now)
    }

    var effectiveAnalyticsDate: Date {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let cutH = min(6, max(0, analyticsDayCutoffHour))
        guard let boundary = cal.date(byAdding: .hour, value: cutH, to: todayStart) else {
            return todayStart
        }
        if now >= boundary {
            return todayStart
        }
        return cal.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
    }

    init() {
        // По умолчанию Apple Health (MVP); Huawei — по явному выбору, когда задан API.
        let raw = UserDefaults.standard.string(forKey: Self.modeKey) ?? DataSourceMode.appleHealth.rawValue
        dataSourceMode = DataSourceMode(rawValue: raw) ?? .appleHealth
        huaweiAutoEndpointURL = Self.normalizedHuaweiEndpointString(
            UserDefaults.standard.string(forKey: Self.huaweiAutoEndpointKey) ?? ""
        )
        huaweiAutoAccessToken = UserDefaults.standard.string(forKey: Self.huaweiAutoTokenKey) ?? ""
        if let ts = UserDefaults.standard.object(forKey: Self.huaweiAutoLastSyncKey) as? TimeInterval {
            lastHuaweiAutoSyncAt = Date(timeIntervalSince1970: ts)
        } else {
            lastHuaweiAutoSyncAt = nil
        }
        let sk = UserDefaults.standard.string(forKey: Self.huaweiSourceKindKey) ?? HuaweiSourceKind.healthApp.rawValue
        huaweiSourceKind = HuaweiSourceKind(rawValue: sk) ?? .healthApp
        if UserDefaults.standard.object(forKey: Self.huaweiAutoSyncEnabledKey) == nil {
            huaweiAutoSyncEnabled = true
        } else {
            huaweiAutoSyncEnabled = UserDefaults.standard.bool(forKey: Self.huaweiAutoSyncEnabledKey)
        }
        // `integer(forKey:)` = 0 если ключа нет, поэтому нельзя сразу трактовать как «00:00» — тогда
        // `h < 0` и никогда не включится вчера+сегодня. Явно отсутствующий ключ → 04:00 по умолчанию.
        if UserDefaults.standard.object(forKey: Self.analyticsDayCutoffHourKey) == nil {
            analyticsDayCutoffHour = 4
            UserDefaults.standard.set(4, forKey: Self.analyticsDayCutoffHourKey)
        } else {
            let cut = UserDefaults.standard.integer(forKey: Self.analyticsDayCutoffHourKey)
            analyticsDayCutoffHour = (0 ... 6).contains(cut) ? cut : 4
        }
        loadHuaweiHistory()
    }

    /// После «Выйти из аккаунта»: убираем endpoint/token и связанное с облаком, чтобы не тянуть данные прежнего пользователя.
    func clearAccountLinkedCloudDefaults() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.huaweiAutoEndpointKey)
        d.removeObject(forKey: Self.huaweiAutoTokenKey)
        d.removeObject(forKey: Self.huaweiAutoLastSyncKey)
        d.removeObject(forKey: Self.renderDeviceIdKey)
        huaweiAutoEndpointURL = ""
        huaweiAutoAccessToken = ""
        lastHuaweiAutoSyncAt = nil
        huaweiPayloadIsDemo = false
    }

    /// Records to push to backend: full Huawei history, or one row from Apple Health summary for the analytics day.
    func healthRecordsForBackendUpload() -> [DayHealthDailyRecord] {
        switch dataSourceMode {
        case .appleHealth:
            // Дата строки = календарный день сегодня, как у шагов/ккал (не сдвиг `effectiveAnalyticsDate` до 4:00).
            let iso = dayISO(for: Calendar.current.startOfDay(for: Date()))
            guard let s = summary else { return [] }
            return [
                DayHealthDailyRecord(
                    dateISO: iso,
                    steps: s.stepsToday,
                    activeEnergyKcal: s.activeEnergyKcal,
                    sleepHours: s.sleepLastNightHours
                ),
            ]
        case .huaweiManual, .huaweiAuto:
            return huaweiManualHistory
        }
    }

    /// Выгрузка дневных строк на ваш Node-сервер (Render) с тем же Bearer, что и Huawei bridge. Без Supabase.
    func syncToRenderBackend() async {
        lastRenderUploadMessage = nil
        guard isHuaweiAutoConfigured else {
            lastRenderUploadMessage = "Укажите URL и токен backend в Health services."
            return
        }
        guard let url = renderHealthDailyUploadURL() else {
            lastRenderUploadMessage = "Неверный URL backend."
            return
        }
        if dataSourceMode == .appleHealth {
            await reloadSummary()
        }
        let fromHealth = healthRecordsForBackendUpload()
        var recs = fromHealth
        if recs.isEmpty {
            let iso = dayISO(for: effectiveAnalyticsDate)
            recs = [
                DayHealthDailyRecord(dateISO: iso, steps: nil, activeEnergyKcal: nil, sleepHours: nil),
            ]
        }

        struct Row: Encodable {
            let date_iso: String
            let steps: Int?
            let active_energy_kcal: Double?
            let sleep_hours: Double?
        }
        struct Body: Encodable {
            let deviceId: String
            let records: [Row]
        }
        let payload = Body(
            deviceId: stableRenderDeviceId,
            records: recs.map {
                Row(
                    date_iso: String($0.dateISO.prefix(10)),
                    steps: $0.steps,
                    active_energy_kcal: $0.activeEnergyKcal,
                    sleep_hours: $0.sleepHours
                )
            }
        )
        guard let bodyData = try? JSONEncoder().encode(payload) else {
            lastRenderUploadMessage = "Не удалось сформировать JSON."
            return
        }

        renderUploadInProgress = true
        defer { renderUploadInProgress = false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(
            "Bearer \(huaweiAutoAccessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        req.httpBody = bodyData
        req.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastRenderUploadMessage = "Нет HTTP-ответа."
                return
            }
            if (200 ... 299).contains(http.statusCode) {
                lastRenderUploadAt = Date()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let merged = obj["merged"] as? Int {
                    lastRenderUploadMessage =
                        "Сервер принял \(merged) строк. Устройство: \(stableRenderDeviceId.prefix(8))…"
                } else {
                    lastRenderUploadMessage = "Сервер принял данные."
                }
            } else {
                let hint = String(data: data, encoding: .utf8) ?? ""
                lastRenderUploadMessage = "HTTP \(http.statusCode): \(hint.prefix(240))"
            }
        } catch {
            lastRenderUploadMessage = error.localizedDescription
        }
    }

    func refreshAuthorizationState() async {
        #if os(iOS) && canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            return
        }
        let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)!
        let status = healthStore.authorizationStatus(for: stepType)
        let askedBefore = UserDefaults.standard.bool(forKey: Self.hasRequestedHealthReadKey)
        var next: HealthAuthorizationState
        switch status {
        case .notDetermined:
            next = askedBefore ? .sharingAuthorized : .shouldRequest
        case .sharingDenied:
            next = .denied
        case .sharingAuthorized:
            next = .sharingAuthorized
        @unknown default:
            next = askedBefore ? .sharingAuthorized : .unknown
        }
        // Read-only: `authorizationStatus` врёт (часто `.sharingDenied`), пока в Health включены тумблеры чтения. Реальная проверка — тестовый `HKSampleQuery`.
        if next == .denied, await readAccessProbeSucceeds() {
            next = .sharingAuthorized
        }
        authorizationState = next
        #else
        authorizationState = .unavailable
        #endif
    }

    func requestAccess() async {
        #if os(iOS) && canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            return
        }
        let types: Set<HKObjectType> = [
            HKObjectType.quantityType(forIdentifier: .stepCount)!,
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
        ]
        do {
            try await healthStore.requestAuthorization(toShare: [], read: types)
            UserDefaults.standard.set(true, forKey: Self.hasRequestedHealthReadKey)
            await refreshAuthorizationState()
            await reloadSummary()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
        #endif
    }

    func reloadSummary() async {
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        switch dataSourceMode {
        case .appleHealth:
            await reloadFromAppleHealth()
        case .huaweiManual, .huaweiAuto:
            if dataSourceMode == .huaweiAuto, isHuaweiAutoConfigured {
                await syncHuaweiAutoNow()
            } else {
                summary = summaryFromHistoryForEffectiveDay()
            }
        }
    }

    private func reloadFromAppleHealth() async {
        #if os(iOS) && canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            summary = nil
            return
        }
        // Явный отказ — не пытаемся читать. Остальное: после `request` и при кваке notDetermined+read считаем, что read можно пробовать.
        if authorizationState == .denied || authorizationState == .unavailable {
            summary = nil
            return
        }
        if authorizationState == .shouldRequest, !UserDefaults.standard.bool(forKey: Self.hasRequestedHealthReadKey) {
            summary = nil
            return
        }
        if authorizationState == .unknown, !UserDefaults.standard.bool(forKey: Self.hasRequestedHealthReadKey) {
            summary = nil
            return
        }

        let steps = await querySteps()
        let energy = await queryEnergy()
        let sleep = await querySleepHours()
        let extended = isInNightExtendedActivityWindow
        summary = DayHealthSummary(
            stepsToday: steps,
            activeEnergyKcal: energy,
            sleepLastNightHours: sleep,
            stepsAndEnergyAreNightExtendedSlice: extended
        )
        #else
        summary = nil
        #endif
    }

    #if os(iOS) && canImport(HealthKit)
    /// Реальное «можно ли читать шаги» — `authorizationStatus` для read-only ненадёжен.
    private func readAccessProbeSucceeds() async -> Bool {
        guard let step = HKObjectType.quantityType(forIdentifier: .stepCount) else { return false }
        return await withCheckedContinuation { cont in
            let from = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let pred = HKQuery.predicateForSamples(withStart: from, end: Date(), options: .strictStartDate)
            let q = HKSampleQuery(
                sampleType: step,
                predicate: pred,
                limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, _, error in
                if error == nil {
                    DispatchQueue.main.async { cont.resume(returning: true) }
                    return
                }
                let ns = error! as NSError
                if ns.domain == HKError.errorDomain, ns.code == HKError.errorAuthorizationDenied.rawValue {
                    DispatchQueue.main.async { cont.resume(returning: false) }
                } else if ns.domain == HKError.errorDomain, ns.code == HKError.errorAuthorizationNotDetermined.rawValue {
                    DispatchQueue.main.async { cont.resume(returning: false) }
                } else {
                    // Иные ошибки — осторожно считаем, что read недоступен; при необходимости снимите, если в логах сеть и т.д.
                    DispatchQueue.main.async { cont.resume(returning: false) }
                }
            }
            healthStore.execute(q)
        }
    }

    private func querySteps() async -> Int? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        let end = Date()
        let start = startOfStepsOrEnergyQueryInterval
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                let val = stats?.sumQuantity()?.doubleValue(for: HKUnit.count())
                cont.resume(returning: val.map { Int($0.rounded()) })
            }
            healthStore.execute(q)
        }
    }

    private func queryEnergy() async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return nil }
        let end = Date()
        let start = startOfStepsOrEnergyQueryInterval
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                let kcal = stats?.sumQuantity()?.doubleValue(for: HKUnit.kilocalorie())
                cont.resume(returning: kcal)
            }
            healthStore.execute(q)
        }
    }

    private func querySleepHours() async -> Double? {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let cal = Calendar.current
        // Раньше `end` = effectiveAnalyticsDate мог быть «вчера 00:00» ночью, и сон, **закончившийся** сегодня, не попадал. Берём с **вчера 00:00** до **сейчас**.
        let end = Date()
        guard let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: end)) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                guard let cats = samples as? [HKCategorySample] else {
                    cont.resume(returning: nil)
                    return
                }
                var asleepSec: Double = 0
                for s in cats {
                    switch s.value {
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                         HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                         HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                         HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        asleepSec += s.endDate.timeIntervalSince(s.startDate)
                    default:
                        break
                    }
                }
                cont.resume(returning: asleepSec > 60 ? asleepSec / 3600 : nil)
            }
            healthStore.execute(q)
        }
    }
    #endif

    private func dayISO(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func summaryFromHistoryForEffectiveDay() -> DayHealthSummary? {
        let key = dayISO(for: effectiveAnalyticsDate)
        guard let rec = huaweiManualHistory.first(where: { $0.dateISO == key }) else { return nil }
        return DayHealthSummary(
            stepsToday: rec.steps,
            activeEnergyKcal: rec.activeEnergyKcal,
            sleepLastNightHours: rec.sleepHours,
            stepsAndEnergyAreNightExtendedSlice: isInNightExtendedActivityWindow
        )
    }

    func connectHuaweiAuto(endpointURL: String, accessToken: String) async {
        huaweiAutoEndpointURL = Self.normalizedHuaweiEndpointString(endpointURL)
        huaweiAutoAccessToken = accessToken
        await syncHuaweiAutoNow()
    }

    func disconnectHuaweiAuto() {
        huaweiAutoEndpointURL = ""
        huaweiAutoAccessToken = ""
        lastHuaweiAutoSyncAt = nil
        lastErrorMessage = nil
        huaweiPayloadIsDemo = false
    }

    func syncHuaweiAutoNow() async {
        guard isHuaweiAutoConfigured else {
            lastErrorMessage = "Укажите URL и токен."
            return
        }
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        do {
            let payload = try await fetchHuaweiAutoPayload()
            huaweiPayloadIsDemo = payload.isDemoData
            var s = payload.summary
            s.stepsAndEnergyAreNightExtendedSlice = isInNightExtendedActivityWindow
            summary = s
            mergeHistory(payload.history)
            let todayISO = dayISO(for: effectiveAnalyticsDate)
            mergeHistory([
                DayHealthDailyRecord(
                    dateISO: todayISO,
                    steps: s.stepsToday,
                    activeEnergyKcal: s.activeEnergyKcal,
                    sleepHours: s.sleepLastNightHours
                ),
            ])
            lastHuaweiAutoSyncAt = Date()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private struct HuaweiPayload {
        var summary: DayHealthSummary
        var history: [DayHealthDailyRecord]
        var isDemoData: Bool
    }

    private func fetchHuaweiAutoPayload() async throws -> HuaweiPayload {
        let raw = Self.normalizedHuaweiEndpointString(huaweiAutoEndpointURL)
        if raw != huaweiAutoEndpointURL {
            huaweiAutoEndpointURL = raw
        }
        let token = huaweiAutoAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 45
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            var hint = ""
            if http.statusCode == 404 {
                hint = " Проверьте адрес: …/v1/huawei/summary (часто вставляют только домен без пути)."
            } else if http.statusCode == 401 {
                hint = " Токен в приложении должен совпадать с API_TOKEN на сервере."
            }
            throw NSError(
                domain: "HuaweiSync",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)\(hint)"]
            )
        }

        return try parseHuaweiJSON(data)
    }

    private func parseHuaweiJSON(_ data: Data) throws -> HuaweiPayload {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = obj as? [String: Any] else {
            throw NSError(domain: "HuaweiSync", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON root"])
        }

        func double(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let s = any as? String { return Double(s) }
            return nil
        }

        func intVal(_ any: Any?) -> Int? {
            if let i = any as? Int { return i }
            if let d = any as? Double { return Int(d.rounded()) }
            if let s = any as? String { return Int(s) }
            return nil
        }

        var summaryDict = root["summary"] as? [String: Any]
        if summaryDict == nil {
            summaryDict = root["today"] as? [String: Any]
        }
        if summaryDict == nil {
            summaryDict = root["latest"] as? [String: Any]
        }

        let steps = intVal(summaryDict?["steps"] ?? summaryDict?["stepsToday"])
        let energy = double(summaryDict?["activeEnergyKcal"] ?? summaryDict?["energyKcal"])
        let sleep = double(summaryDict?["sleepLastNightHours"] ?? summaryDict?["sleepHours"])

        let summary = DayHealthSummary(
            stepsToday: steps,
            activeEnergyKcal: energy,
            sleepLastNightHours: sleep
        )

        var history: [DayHealthDailyRecord] = []
        if let arr = root["history"] as? [[String: Any]] {
            for item in arr {
                let d = (item["dateISO"] as? String) ?? (item["date"] as? String) ?? ""
                guard !d.isEmpty else { continue }
                let iso = normalizeDateISO(d)
                history.append(
                    DayHealthDailyRecord(
                        dateISO: iso,
                        steps: intVal(item["steps"]),
                        activeEnergyKcal: double(item["activeEnergyKcal"] ?? item["energyKcal"]),
                        sleepHours: double(item["sleepHours"] ?? item["sleepLastNightHours"])
                    )
                )
            }
        }

        let mockFlag = root["mock"] as? Bool
        let ds = ((root["dataSource"] as? String) ?? "").lowercased()
        let isDemo: Bool
        if mockFlag == true || ds == "mock" || ds == "demo" || ds == "synthetic" {
            isDemo = true
        } else if ds == "live_stub" || ds.hasSuffix("_stub") {
            isDemo = true
        } else if ds == "live" || ds == "production" || ds == "huawei_cloud" {
            isDemo = false
        } else {
            isDemo = false
        }

        return HuaweiPayload(summary: summary, history: history, isDemoData: isDemo)
    }

    private func normalizeDateISO(_ s: String) -> String {
        let parts = s.prefix(10)
        return String(parts)
    }

    private func mergeHistory(_ incoming: [DayHealthDailyRecord]) {
        guard !incoming.isEmpty else { return }
        var map: [String: DayHealthDailyRecord] = [:]
        for r in huaweiManualHistory {
            map[r.dateISO] = r
        }
        for r in incoming {
            map[r.dateISO] = r
        }
        huaweiManualHistory = map.values.sorted { $0.dateISO < $1.dateISO }
        saveHuaweiHistory()
    }

    private func loadHuaweiHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.huaweiHistoryKey) else { return }
        if let decoded = try? JSONDecoder().decode([DayHealthDailyRecord].self, from: data) {
            huaweiManualHistory = decoded
        }
    }

    private func saveHuaweiHistory() {
        if let data = try? JSONEncoder().encode(huaweiManualHistory) {
            UserDefaults.standard.set(data, forKey: Self.huaweiHistoryKey)
        }
    }
}
