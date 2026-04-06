import Foundation
import Combine

#if canImport(HealthKit) && os(iOS)
import HealthKit

/// Сводка за день / прошлую ночь из Apple Health (только чтение).
struct DayHealthSummary: Sendable, Equatable {
    var stepsToday: Int?
    var activeEnergyKcal: Double?
    /// Суммарный сон «asleep» за прошлую ночь (примерно 18:00 вчера — 14:00 сегодня).
    var sleepLastNightHours: Double?
}

@MainActor
final class DayHealthInsightsStore: ObservableObject {
    @Published private(set) var authorizationState: HealthAuthState = .unknown
    @Published private(set) var summary: DayHealthSummary?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isLoading = false

    private let healthStore = HKHealthStore()

    enum HealthAuthState: Equatable {
        case unknown
        case unavailable
        case shouldRequest
        case denied
        case sharingAuthorized
    }

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    private func buildReadTypes() -> Set<HKObjectType> {
        var readTypes = Set<HKObjectType>()
        if let t = HKQuantityType.quantityType(forIdentifier: .stepCount) { readTypes.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { readTypes.insert(t) }
        if let t = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { readTypes.insert(t) }
        return readTypes
    }

    func refreshAuthorizationState() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            return
        }
        let readTypes = buildReadTypes()
        guard !readTypes.isEmpty else {
            authorizationState = .unavailable
            return
        }
        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount),
           healthStore.authorizationStatus(for: stepType) == .sharingDenied {
            authorizationState = .denied
            return
        }
        let status = await requestStatusForAuthorization(readTypes: readTypes)
        switch status {
        case .shouldRequest:
            authorizationState = .shouldRequest
        case .unnecessary:
            authorizationState = .sharingAuthorized
        @unknown default:
            authorizationState = .shouldRequest
        }
    }

    private func requestStatusForAuthorization(readTypes: Set<HKObjectType>) async -> HKAuthorizationRequestStatus {
        await withCheckedContinuation { cont in
            healthStore.getRequestStatusForAuthorization(toShare: Set<HKSampleType>(), read: readTypes) { status, _ in
                cont.resume(returning: status)
            }
        }
    }

    func requestAccess() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            lastErrorMessage = "Health недоступен на этом устройстве."
            return
        }
        let readTypes = buildReadTypes()
        guard !readTypes.isEmpty else {
            authorizationState = .unavailable
            return
        }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            await refreshAuthorizationState()
            await reloadSummary()
        } catch {
            lastErrorMessage = error.localizedDescription
            await refreshAuthorizationState()
        }
    }

    func reloadSummary() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard authorizationState == .sharingAuthorized else {
            summary = nil
            return
        }
        isLoading = true
        lastErrorMessage = nil
        defer { isLoading = false }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)

        async let steps = fetchStepCount(from: startOfToday, to: now)
        async let energy = fetchActiveEnergy(from: startOfToday, to: now)
        async let sleep = fetchSleepLastNight(endingOn: now, calendar: calendar)

        summary = DayHealthSummary(
            stepsToday: await steps,
            activeEnergyKcal: await energy,
            sleepLastNightHours: await sleep
        )
    }

    // MARK: - Queries

    private func fetchStepCount(from start: Date, to end: Date) async -> Int? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        return await withCheckedContinuation { cont in
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: pred,
                options: .cumulativeSum
            ) { _, stats, error in
                if error != nil {
                    cont.resume(returning: nil)
                    return
                }
                let unit = HKUnit.count()
                let q = stats?.sumQuantity()?.doubleValue(for: unit)
                if let q {
                    cont.resume(returning: Int(q.rounded()))
                } else {
                    cont.resume(returning: nil)
                }
            }
            healthStore.execute(query)
        }
    }

    private func fetchActiveEnergy(from start: Date, to end: Date) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return nil }
        return await withCheckedContinuation { cont in
            let pred = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: pred,
                options: .cumulativeSum
            ) { _, stats, error in
                if error != nil {
                    cont.resume(returning: nil)
                    return
                }
                let q = stats?.sumQuantity()?.doubleValue(for: HKUnit.kilocalorie())
                cont.resume(returning: q)
            }
            healthStore.execute(query)
        }
    }

    private func fetchSleepLastNight(endingOn now: Date, calendar: Calendar) async -> Double? {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let startOfToday = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .hour, value: -14, to: startOfToday),
              let windowEnd = calendar.date(byAdding: .hour, value: 14, to: startOfToday) else {
            return nil
        }
        return await withCheckedContinuation { cont in
            let pred = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: .strictStartDate)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if error != nil {
                    cont.resume(returning: nil)
                    return
                }
                guard let cats = samples as? [HKCategorySample] else {
                    cont.resume(returning: nil)
                    return
                }
                let asleepRaw = Set([
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue
                ])
                var asleepSeconds: TimeInterval = 0
                for s in cats where asleepRaw.contains(s.value) {
                    asleepSeconds += s.endDate.timeIntervalSince(s.startDate)
                }
                let hours = asleepSeconds / 3600.0
                cont.resume(returning: hours > 0.05 ? hours : nil)
            }
            healthStore.execute(query)
        }
    }
}

enum DayHealthTipBuilder {
    static func tips(from summary: DayHealthSummary?) -> String {
        guard let s = summary else {
            return "Разрешите доступ к Health — покажем шаги за сегодня и сон прошлой ночью, и короткую подсказку к вечеру."
        }
        var lines: [String] = []
        if let steps = s.stepsToday {
            lines.append("Шаги сегодня: \(steps.formatted(.number.grouping(.automatic))).")
            if steps < 2_500 {
                lines.append("Движения мало — если можно, короткая прогулка до сна помогает отключиться.")
            } else if steps > 9_000 {
                lines.append("Активный день — к вечеру можно чуть раньше начать затихание.")
            }
        }
        if let kcal = s.activeEnergyKcal, kcal >= 1 {
            lines.append("Активность: ~\(Int(kcal.rounded())) ккал.")
        }
        if let h = s.sleepLastNightHours {
            lines.append("Сон прошлой ночью: ~\(formatHours(h)).")
            if h < 6 {
                lines.append("Сна было мало — сегодня лучше не сдвигать подъём поздно и упростить вечер.")
            } else if h >= 7.5 {
                lines.append("Нормальный объём сна — хорошая база для завтрашнего подъёма.")
            }
        } else if s.stepsToday != nil {
            lines.append("За выбранное окно данных о сне в Health не нашлось — проверьте Apple Watch или другое устройство.")
        }
        if lines.isEmpty {
            return "Данных пока нет. Убедитесь, что шаги и сон пишутся в приложение «Здоровье»."
        }
        return lines.joined(separator: " ")
    }

    private static func formatHours(_ h: Double) -> String {
        let t = (h * 10).rounded() / 10
        if t == floor(t) {
            return "\(Int(t)) ч"
        }
        return String(format: "%.1f ч", t)
    }
}

#else

/// Заглушка на macOS / без HealthKit.
struct DayHealthSummary: Sendable, Equatable {
    var stepsToday: Int?
    var activeEnergyKcal: Double?
    var sleepLastNightHours: Double?
}

@MainActor
final class DayHealthInsightsStore: ObservableObject {
    enum HealthAuthState: Equatable {
        case unknown
        case unavailable
        case shouldRequest
        case denied
        case sharingAuthorized
    }

    @Published private(set) var authorizationState: HealthAuthState = .unavailable
    @Published private(set) var summary: DayHealthSummary?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isLoading = false

    var isHealthDataAvailable: Bool { false }

    func refreshAuthorizationState() async {
        authorizationState = .unavailable
    }

    func requestAccess() async {}

    func reloadSummary() async {
        summary = nil
    }
}

enum DayHealthTipBuilder {
    static func tips(from summary: DayHealthSummary?) -> String {
        "Apple Health доступен в версии для iPhone — здесь сводка не подключается."
    }
}

#endif
