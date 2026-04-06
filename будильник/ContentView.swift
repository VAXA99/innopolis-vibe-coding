// ContentView.swift
import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit
import UserNotifications

struct ContentView: View {
    @StateObject private var alarmVM = AlarmViewModel()
    @StateObject private var sleepVM = SleepViewModel()
    @StateObject private var musicAlarmManager = AppleMusicAlarmManager()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSoundStep = false
    @State private var showSleepMode = false
    @State private var showStats = false
    @State private var showWakeResult = false

    var body: some View {
        NavigationStack {
            AlarmSetupStepView(
                alarmVM: alarmVM,
                musicAlarmManager: musicAlarmManager,
                onNext: { showSoundStep = true },
                onOpenStats: { showStats = true }
            )
            .navigationDestination(isPresented: $showSoundStep) {
                SoundSetupStepView(sleepVM: sleepVM, alarmVM: alarmVM, isEditingActiveSleepSession: false) {
                    showSleepMode = true
                }
            }
            .navigationDestination(isPresented: $showSleepMode) {
                SleepModeStepView(sleepVM: sleepVM, alarmVM: alarmVM) {
                    showSleepMode = false
                }
            }
            .navigationDestination(isPresented: $showStats) {
                StatsStepView(sleepVM: sleepVM)
            }
            .navigationTitle("Smart Alarm")
            .preferredColorScheme(.dark)
            .task {
                await alarmVM.requestNotificationPermissionIfNeeded()
            }
            .onChange(of: sleepVM.lastSession != nil) { _, hasSession in
                showWakeResult = hasSession
            }
            .sheet(isPresented: $showWakeResult) {
                if let session = sleepVM.lastSession {
                    WakeResultView(
                        session: session,
                        onContinue: {
                            sleepVM.markAsWokeUp()
                            showWakeResult = false
                        },
                        onOpenStats: {
                            sleepVM.markAsWokeUp()
                            showWakeResult = false
                            showStats = true
                        }
                    )
                }
            }
            .onAppear {
                sleepVM.syncSleepUIWhenViewAppears()
            }
            .task(id: sleepVM.isRunning) {
                guard sleepVM.isRunning else { return }
                showSoundStep = true
                showSleepMode = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                sleepVM.syncSleepUIWhenViewAppears()
                Task { await reconcileDeliveredWakeNotifications(sleepVM: sleepVM, alarmVM: alarmVM) }
            }
            .onChange(of: scenePhase) { _, phase in
                sleepVM.handleScenePhaseChange(phase)
            }
            .onReceive(NotificationCenter.default.publisher(for: .smartAlarmDidFire)) { note in
                let fireDate = note.userInfo?[Notification.Name.smartAlarmFireDateUserInfoKey] as? Date ?? Date()
                AlarmPlaybackAnchor.recordIfNeeded(fireDate)
                if sleepVM.isRunning && sleepVM.sleepUIMode == .sleeping {
                    sleepVM.handleExternalAlarmFired()
                } else if sleepVM.isRunning && sleepVM.sleepUIMode == .alarmRinging {
                    sleepVM.reassertAlarmPlaybackFromForegroundIfNeeded()
                } else if !sleepVM.isRunning {
                    alarmVM.playAlarmFromNotification(notificationDeliveryDate: fireDate)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .userDismissedMorningAlarm)) { _ in
                alarmVM.syncMorningAlarmDismissedState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sleepTimerDidEnd)) { _ in
                // Конец таймера сна: только остановка sleep-сессии, не запуск утреннего будильника.
                if sleepVM.isRunning && sleepVM.sleepUIMode == .sleeping {
                    sleepVM.stopSleep()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alarmRemoteStopRequested)) { _ in
                if sleepVM.isRunning && sleepVM.sleepUIMode == .alarmRinging {
                    sleepVM.dismissAlarmAndFinish()
                } else {
                    alarmVM.stopAlarmRingingFromNotification()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                alarmVM.handleSignificantTimeChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
                alarmVM.handleSignificantTimeChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                alarmVM.handleSignificantTimeChange()
            }
        }
    }
}

private struct AlarmSetupStepView: View {
    @ObservedObject var alarmVM: AlarmViewModel
    @ObservedObject var musicAlarmManager: AppleMusicAlarmManager
    let onNext: () -> Void
    let onOpenStats: () -> Void
    @State private var showMelodySettings = false
    @State private var showAppSettings = false
    @State private var showRepeatDetails = false

    var body: some View {
        ZStack {
            gradientBackground
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Step 1")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.8))
                        Spacer()
                        Button {
                            showAppSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.16))
                                )
                        }
                        .buttonStyle(.plain)
                        Button {
                            onOpenStats()
                        } label: {
                            Label("Statistics", systemImage: "chart.bar.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.16))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Set your wake-up")
                        .font(.largeTitle.weight(.bold))

                    GlassCard {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sleep duration")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(alarmVM.sleepDurationText)
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .foregroundStyle(alarmVM.sleepDurationColor)
                                Text("Time left until wake")
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.65))
                            }
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(alarmVM.sleepDurationColor.opacity(0.2))
                                    .frame(width: 62, height: 62)
                                Image(systemName: "bed.double.fill")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(alarmVM.sleepDurationColor)
                            }
                        }
                    }

                    GlassCard {
                        Text("Default wake time")
                            .font(.headline)
                        Text("Used for days that have no custom time.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        DatePicker(
                            "",
                            selection: $alarmVM.alarmTime,
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                        .datePickerStyle(.wheel)
                    }

                    GlassCard {
                        Text("Repeat")
                            .font(.headline)
                        Text("Tap a day to turn it off.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(0 ..< 7, id: \.self) { offset in
                                let cal = Calendar.current
                                let wd = (cal.firstWeekday - 1 + offset) % 7 + 1
                                let sym = cal.veryShortWeekdaySymbols[wd - 1]
                                let on = alarmVM.alarmWeekdays.contains(wd)
                                Button {
                                    alarmVM.toggleAlarmWeekday(wd)
                                } label: {
                                    Text(sym)
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 36, height: 36)
                                        .background(
                                            Circle()
                                                .fill(on ? Color.indigo.opacity(0.6) : Color.white.opacity(0.12))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        let cal = Calendar.current
                        let orderedWeekdays = (0 ..< 7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showRepeatDetails.toggle()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text("Set custom time for each day")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: showRepeatDetails ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                        .buttonStyle(.plain)

                        if showRepeatDetails {
                            VStack(spacing: 8) {
                                ForEach(orderedWeekdays.filter { alarmVM.alarmWeekdays.contains($0) }, id: \.self) { wd in
                                    HStack {
                                        Text(cal.weekdaySymbols[wd - 1])
                                            .font(.subheadline.weight(.semibold))
                                            .frame(minWidth: 82, alignment: .leading)
                                        DatePicker(
                                            "",
                                            selection: alarmVM.bindingForWeekdayTime(wd),
                                            displayedComponents: [.hourAndMinute]
                                        )
                                        .labelsHidden()
                                        .datePickerStyle(.compact)
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        showMelodySettings = true
                    } label: {
                        GlassCard {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Alarm sound")
                                        .font(.headline)
                                    Group {
                                        switch alarmVM.wakeSoundMode {
                                        case .builtIn:
                                            Text("\(alarmVM.alarmSound.category.title) · \(alarmVM.alarmSound.title)")
                                                .font(.subheadline)
                                                .foregroundStyle(Color.white.opacity(0.9))
                                        case .appleMusic:
                                            if let selected = musicAlarmManager.currentSelection {
                                                Text(selected.subtitle)
                                                    .font(.subheadline)
                                                    .foregroundStyle(Color.white.opacity(0.95))
                                                    .lineLimit(3)
                                            } else {
                                                Text("Apple Music — choose a song")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                        case .localFile:
                                            if let name = alarmVM.localWakeFileDisplayName {
                                                Text(name)
                                                    .font(.subheadline)
                                                    .foregroundStyle(Color.white.opacity(0.95))
                                                    .lineLimit(3)
                                                if alarmVM.lockScreenNotifyReady {
                                                    Text("Lock screen: your track (first ~30 s) · full track when you open the app")
                                                        .font(.caption2)
                                                        .foregroundStyle(Color.white.opacity(0.65))
                                                        .padding(.top, 2)
                                                } else {
                                                    Text("Preparing lock-screen sound… open Alarm sound and pick the file again if needed.")
                                                        .font(.caption2)
                                                        .foregroundStyle(.orange.opacity(0.9))
                                                        .padding(.top, 2)
                                                }
                                            } else {
                                                Text("Files — choose an MP3 or audio file")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    PrimaryGradientButton(title: "Continue to sound mix") {
                        onNext()
                    }
                }
                .padding(20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMelodySettings) {
            AlarmMelodySettingsView(alarmVM: alarmVM, musicAlarmManager: musicAlarmManager)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showAppSettings) {
            AlarmAppSettingsSheet()
                .preferredColorScheme(.dark)
        }
        .onDisappear {
            AlarmSoundPreview.stop()
            musicAlarmManager.stopPreview()
        }
    }
}

private struct AlarmAppSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var healthInsights = DayHealthInsightsStore()
    @State private var snoozeEnabled = AlarmBehaviorSettings.isSnoozeEnabled
    @State private var snoozeMinutes = AlarmBehaviorSettings.snoozeIntervalMinutes
    @State private var snoozeMax = AlarmBehaviorSettings.snoozeMaxCount
    @State private var crescendoOn = AlarmBehaviorSettings.isCrescendoEnabled
    @State private var crescendoSec = Double(AlarmBehaviorSettings.crescendoRampSeconds)
    @State private var alarmVolume = AlarmBehaviorSettings.alarmVolumeMultiplier
    @State private var vibrationOn = AlarmVibrationSettings.isEnabled
    @State private var vibMode = AlarmVibrationSettings.mode
    @State private var interval = AlarmVibrationSettings.pulseIntervalSeconds
    @State private var style = AlarmVibrationSettings.style
    @State private var patternGap = AlarmVibrationSettings.patternRepeatGapSeconds
    @State private var customDraftSamples: [AlarmVibrationSettings.PatternSample] = []

    var body: some View {
        NavigationStack {
            ZStack {
                gradientBackground
                Form {
                    Section {
                        Text(
                            "Короткий сигнал на заблокированном экране — ограничение iOS. Полный звук будильника в приложении идёт по кругу, пока вы его не выключите."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } header: {
                        Text("Звук и уведомления")
                    }

                    Section {
                        Text("На шаге 1: время, дни недели, мелодия. Здесь: snooze, нарастание громкости в приложении, вибрация.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Что обычно бывает в будильниках")
                    }

                    Section {
                        Toggle("Snooze", isOn: $snoozeEnabled)
                        Picker("Интервал snooze", selection: $snoozeMinutes) {
                            Text("5 мин").tag(5)
                            Text("9 мин").tag(9)
                            Text("10 мин").tag(10)
                            Text("15 мин").tag(15)
                            Text("20 мин").tag(20)
                        }
                        .disabled(!snoozeEnabled)
                        Stepper(value: $snoozeMax, in: 0 ... 20) {
                            Text(snoozeMax == 0 ? "Лимит snooze: без лимита" : "Лимит snooze: \(snoozeMax)× за серию")
                        }
                        .disabled(!snoozeEnabled)
                        Toggle("Плавное нарастание громкости", isOn: $crescendoOn)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Длительность нарастания: \(Int(crescendoSec)) с")
                                .font(.subheadline)
                            Slider(value: $crescendoSec, in: 10 ... 120, step: 5)
                        }
                        .disabled(!crescendoOn)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Громкость в приложении: \(Int(alarmVolume * 100))%")
                                .font(.subheadline)
                            Slider(value: $alarmVolume, in: 0.2 ... 1.0, step: 0.05)
                        }
                    } header: {
                        Text("Будильник")
                    } footer: {
                        Text("Плавное нарастание и слайдер громкости: встроенные рингтоны, файл из «Файлы», запасной рингтон. Трек из медиатеки / Apple Music — громкость как у обычного плеера (iOS не даёт плавный подъём программно).")
                            .font(.caption2)
                    }

                    Section {
                        Toggle("Вибрация у будильника", isOn: $vibrationOn)
                        Picker("Как вибрировать", selection: $vibMode) {
                            ForEach(AlarmVibrationSettings.Mode.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        if vibMode == .standard {
                            Picker("Тип", selection: $style) {
                                ForEach(AlarmVibrationSettings.Style.allCases) { s in
                                    Text(s.title).tag(s)
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Интервал между импульсами: \(String(format: "%.1f", interval)) с")
                                    .font(.subheadline)
                                Slider(value: $interval, in: 0.8 ... 6.0, step: 0.1)
                            }
                            Button("Тест — один импульс") {
                                persist()
                                AlarmVibrationSettings.playStandardSamplePulse()
                            }
                            .disabled(!vibrationOn)
                        } else {
                            Text("Ниже — площадка: «Начать запись» → рисуете → «Стоп» — сразу слышите результат. «Готово» вверху сохраняет рисунок в будильник.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            AlarmVibrationCustomPatternPad(samples: $customDraftSamples)
                                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                                .listRowBackground(Color.clear)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Тишина между повторами рисунка: \(String(format: "%.1f", patternGap)) с")
                                    .font(.subheadline)
                                Slider(value: $patternGap, in: 0.5 ... 7.0, step: 0.1)
                            }
                        }
                    } header: {
                        Text("Вибрация")
                    } footer: {
                        Text("Пока будильник звенит, рисунок проигрывается по кругу. «Тишина между повторами» — сколько секунд тишины после одного полного прохода рисунка до следующего. Свой рисунок — это Taptic в приложении, не отдельный файл вибрации iOS.")
                            .font(.caption2)
                    }

                    Section {
                        AlarmHealthDaySettingsBlock(store: healthInsights)
                    } header: {
                        Text("Сон и день")
                    } footer: {
                        Text("С Personal Team (бесплатный Apple ID) Apple не выдаёт профиль с HealthKit — раздел «Здоровье» в настройках будет недоступен до участия в Apple Developer Program. Сводка не уходит с устройства.")
                            .font(.caption2)
                    }

                    Section {
                        Text("Smart Alarm · режим сна и микс")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } header: {
                        Text("О приложении")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        persist()
                        dismiss()
                    }
                }
            }
            .onAppear {
                snoozeEnabled = AlarmBehaviorSettings.isSnoozeEnabled
                snoozeMinutes = AlarmBehaviorSettings.snoozeIntervalMinutes
                snoozeMax = AlarmBehaviorSettings.snoozeMaxCount
                crescendoOn = AlarmBehaviorSettings.isCrescendoEnabled
                crescendoSec = Double(AlarmBehaviorSettings.crescendoRampSeconds)
                alarmVolume = AlarmBehaviorSettings.alarmVolumeMultiplier
                vibrationOn = AlarmVibrationSettings.isEnabled
                vibMode = AlarmVibrationSettings.mode
                interval = AlarmVibrationSettings.pulseIntervalSeconds
                style = AlarmVibrationSettings.style
                patternGap = AlarmVibrationSettings.patternRepeatGapSeconds
                if vibMode == .customPattern {
                    customDraftSamples = AlarmVibrationSettings.loadCustomPattern()
                }
                Task {
                    await healthInsights.refreshAuthorizationState()
                    await healthInsights.reloadSummary()
                }
            }
            .onChange(of: vibMode) { _, newMode in
                if newMode == .customPattern {
                    customDraftSamples = AlarmVibrationSettings.loadCustomPattern()
                }
            }
            .onDisappear {
                persist()
            }
        }
    }

    private func persist() {
        AlarmBehaviorSettings.isSnoozeEnabled = snoozeEnabled
        AlarmBehaviorSettings.snoozeIntervalMinutes = snoozeMinutes
        AlarmBehaviorSettings.snoozeMaxCount = snoozeMax
        AlarmBehaviorSettings.isCrescendoEnabled = crescendoOn
        AlarmBehaviorSettings.crescendoRampSeconds = Int(crescendoSec)
        AlarmBehaviorSettings.alarmVolumeMultiplier = alarmVolume
        AlarmVibrationSettings.isEnabled = vibrationOn
        AlarmVibrationSettings.mode = vibMode
        AlarmVibrationSettings.pulseIntervalSeconds = interval
        AlarmVibrationSettings.style = style
        AlarmVibrationSettings.patternRepeatGapSeconds = patternGap
        if vibMode == .customPattern {
            let norm = AlarmVibrationSettings.normalizeCustomPatternTimeline(customDraftSamples)
            if norm.isEmpty {
                AlarmVibrationSettings.clearCustomPattern()
            } else {
                AlarmVibrationSettings.saveCustomPattern(norm)
            }
        }
    }
}

private struct AlarmHealthDaySettingsBlock: View {
    @ObservedObject var store: DayHealthInsightsStore

    var body: some View {
        #if os(iOS)
        Group {
            if !store.isHealthDataAvailable {
                Text("«Здоровье» на этом устройстве недоступно.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                switch store.authorizationState {
                case .unavailable:
                    Text("Не удалось подключиться к Health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .denied:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Доступ к данным Health отклонён. Включите чтение шагов и сна в Настройках.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Открыть настройки приложения") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }
                case .shouldRequest, .unknown:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Покажем шаги за сегодня, сон прошлой ночью и короткую подсказку к вечеру.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Разрешить доступ к Health") {
                            Task { await store.requestAccess() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }
                case .sharingAuthorized:
                    authorizedContent
                }
            }
            if let err = store.lastErrorMessage, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        #else
        Text(DayHealthTipBuilder.tips(from: nil))
            .font(.caption)
            .foregroundStyle(.secondary)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var authorizedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Загружаем данные…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let s = store.summary {
                VStack(alignment: .leading, spacing: 6) {
                    if let steps = s.stepsToday {
                        LabeledContent("Шаги сегодня") {
                            Text(steps.formatted(.number.grouping(.automatic)))
                        }
                    }
                    if let kcal = s.activeEnergyKcal, kcal >= 1 {
                        LabeledContent("Активность") {
                            Text("≈ \(Int(kcal.rounded())) ккал")
                        }
                    }
                    if let sleep = s.sleepLastNightHours {
                        LabeledContent("Сон прошлой ночью") {
                            Text(formatSleepHours(sleep))
                        }
                    }
                }
                .font(.subheadline)
            }
            Text(DayHealthTipBuilder.tips(from: store.summary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Обновить данные") {
                Task { await store.reloadSummary() }
            }
            .buttonStyle(.bordered)
        }
    }

    private func formatSleepHours(_ h: Double) -> String {
        let t = (h * 10).rounded() / 10
        if t == floor(t) {
            return "~\(Int(t)) ч"
        }
        return String(format: "~%.1f ч", t)
    }
    #endif
}

private struct AlarmMelodySettingsView: View {
    @ObservedObject var alarmVM: AlarmViewModel
    @ObservedObject var musicAlarmManager: AppleMusicAlarmManager
    @Environment(\.dismiss) private var dismiss
    @State private var ringtoneCategory: RingtoneCategory = .mechanical
    @State private var showPicker = false
    @State private var showFileImporter = false
    @State private var showAccessError = false
    @State private var importErrorMessage = ""
    @State private var showImportError = false
    @State private var lastSongSavedBanner: String?

    private var builtInSoundBinding: Binding<AlarmSoundOption> {
        Binding(
            get: { alarmVM.alarmSound },
            set: { new in
                alarmVM.alarmSound = new
                alarmVM.persistAlarmSound()
                AlarmSoundPreview.play(new)
            }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                gradientBackground
                VStack(alignment: .leading, spacing: 16) {
                    Text("Alarm sound")
                        .font(.largeTitle.bold())
                        .padding(.top, 8)

                    Picker("", selection: $alarmVM.wakeSoundMode) {
                        Text("Built-in").tag(AlarmWakeSoundMode.builtIn)
                        Text("Apple Music").tag(AlarmWakeSoundMode.appleMusic)
                        Text("Files").tag(AlarmWakeSoundMode.localFile)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: alarmVM.wakeSoundMode) { _, mode in
                        switch mode {
                        case .builtIn:
                            musicAlarmManager.stopPreview()
                            AlarmSoundPreview.stop()
                            ringtoneCategory = alarmVM.alarmSound.category
                        case .appleMusic:
                            AlarmSoundPreview.stop()
                        case .localFile:
                            musicAlarmManager.stopPreview()
                            AlarmSoundPreview.stop()
                        }
                    }

                    if alarmVM.wakeSoundMode == .builtIn {
                        Picker("", selection: $ringtoneCategory) {
                            ForEach(RingtoneCategory.allCases) { cat in
                                Text(cat.title).tag(cat)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: ringtoneCategory) { _, newCat in
                            let list = AlarmSoundOption.sounds(for: newCat)
                            if !list.contains(alarmVM.alarmSound), let first = list.first {
                                alarmVM.alarmSound = first
                                alarmVM.persistAlarmSound()
                            }
                            AlarmSoundPreview.play(alarmVM.alarmSound)
                        }

                        Picker("", selection: builtInSoundBinding) {
                            ForEach(AlarmSoundOption.sounds(for: ringtoneCategory)) { sound in
                                Text(sound.title).tag(sound)
                            }
                        }
                        .pickerStyle(.wheel)
                        Text("Предпросмотр здесь — около 25 секунд. В приложении при звонке будильник играет по кругу, пока вы его не выключите.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if alarmVM.wakeSoundMode == .appleMusic {
                        VStack(alignment: .leading, spacing: 12) {
                            if let selected = musicAlarmManager.currentSelection {
                                Text("Alarm will play:")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(selected.subtitle)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if let banner = lastSongSavedBanner {
                                    Text(banner)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green.opacity(0.95))
                                }
                                HStack(spacing: 16) {
                                    Button("Preview") { musicAlarmManager.previewCurrentSong() }
                                    Button("Clear") {
                                        musicAlarmManager.clearSelection()
                                        alarmVM.wakeSoundMode = .builtIn
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                            } else {
                                Text("Choose a song from your library. It will be the only alarm sound until you switch back to Built-in.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            PrimaryGradientButton(title: "Choose song", systemImage: "music.note.list") {
                                Task {
                                    let granted = await musicAlarmManager.requestAccess()
                                    if granted {
                                        showPicker = true
                                    } else {
                                        showAccessError = true
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Pick MP3, M4A, or WAV from the Files app. We save a copy and prepare a short clip so your sound can play on the lock screen (iOS does not use raw MP3 there). The full file plays when the alarm rings inside the app.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            if let name = alarmVM.localWakeFileDisplayName {
                                Text("Alarm will play:")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(name)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(4)
                                HStack(spacing: 16) {
                                    Button("Preview") {
                                        if let url = AlarmLocalFileStorage.playbackURL() {
                                            AlarmSoundPreview.playFile(at: url)
                                        }
                                    }
                                    Button("Clear", role: .destructive) {
                                        AlarmSoundPreview.stop()
                                        AlarmLocalFileStorage.clear()
                                        alarmVM.localWakeFileDisplayName = nil
                                        alarmVM.wakeSoundMode = .builtIn
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                            }

                            PrimaryGradientButton(title: "Choose audio file", systemImage: "folder") {
                                showFileImporter = true
                            }
                        }
                    }

                    Spacer()
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        AlarmSoundPreview.stop()
                        musicAlarmManager.stopPreview()
                        dismiss()
                    }
                }
            }
            .alert("Apple Music access denied", isPresented: $showAccessError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow Media & Apple Music access in iPhone Settings.")
            }
            .sheet(isPresented: $showPicker) {
                MediaSongPickerSheet(
                    onPick: { item in
                        musicAlarmManager.setSelection(item)
                        alarmVM.wakeSoundMode = .appleMusic
                        if let sel = musicAlarmManager.currentSelection {
                            lastSongSavedBanner = "Saved — \(sel.title)"
                        } else {
                            lastSongSavedBanner = "Saved"
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            lastSongSavedBanner = nil
                        }
                    },
                    onCancel: {}
                )
                .ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.mp3, .mpeg4Audio, .wav, .aiff, .audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    // Важно: доступ security-scoped держим на всё время async-импорта. Если defer был снаружи Task,
                    // он срабатывал до копирования — отсюда «no permission».
                    Task {
                        let access = url.startAccessingSecurityScopedResource()
                        guard access else {
                            await MainActor.run {
                                importErrorMessage = "No access to this file. Pick it again, or copy the file to On My iPhone, then choose it from there."
                                showImportError = true
                            }
                            return
                        }
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            try await AlarmLocalFileStorage.importSecurityScopedFile(from: url)
                            _ = await AlarmLocalFileStorage.prepareLockScreenNotifyClip()
                            await MainActor.run {
                                alarmVM.wakeSoundMode = .localFile
                                alarmVM.localWakeFileDisplayName = AlarmLocalFileStorage.displayName()
                                alarmVM.refreshLockScreenReadiness()
                                alarmVM.persistAlarmSound()
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                        } catch {
                            await MainActor.run {
                                importErrorMessage = error.localizedDescription
                                showImportError = true
                            }
                        }
                    }
                case .failure(let err):
                    importErrorMessage = err.localizedDescription
                    showImportError = true
                }
            }
            .alert("Could not import file", isPresented: $showImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage)
            }
            .onAppear {
                ringtoneCategory = alarmVM.alarmSound.category
                alarmVM.localWakeFileDisplayName = AlarmLocalFileStorage.displayName()
            }
            .onDisappear {
                AlarmSoundPreview.stop()
                musicAlarmManager.stopPreview()
            }
        }
    }
}

private struct SoundSetupStepView: View {
    @ObservedObject var sleepVM: SleepViewModel
    @ObservedObject var alarmVM: AlarmViewModel
    /// Уже идёт таймер сна — только правим микс, без повторного «Go to Sleep» и без сброса круга.
    var isEditingActiveSleepSession: Bool = false
    let onStartSleep: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showAlarmScheduleFailed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            SpatialMixerView(sleepVM: sleepVM, bottomExtraPadding: 88)

            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
            .allowsHitTesting(false)

            if isEditingActiveSleepSession {
                PrimaryGradientButton(title: "Готово", systemImage: "checkmark.circle.fill") {
                    dismiss()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            } else {
                PrimaryGradientButton(title: "Go to Sleep", systemImage: "play.fill") {
                    Task { @MainActor in
                        await alarmVM.scheduleMorningAlarm(windowMinutes: sleepVM.wakeWindowMinutes)
                        guard alarmVM.lastScheduledFireDate != nil else {
                            showAlarmScheduleFailed = true
                            return
                        }
                        sleepVM.startSleep()
                        onStartSleep()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .alert("Alarm not scheduled", isPresented: $showAlarmScheduleFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alarmVM.lastErrorMessage ?? "Allow notifications, set alarm sound, then try again.")
        }
        .navigationTitle(isEditingActiveSleepSession ? "Микс для сна" : "Sound Setup")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            if !isEditingActiveSleepSession, !sleepVM.isRunning {
                sleepVM.spatialPlacedSounds = []
            }
        }
        .onDisappear {
            sleepVM.stopSpatialPreview()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                        Text(isEditingActiveSleepSession ? "Ко сну" : "Back")
                    }
                }
                .tint(.white)
                .transaction { $0.animation = nil }
            }
        }
    }
}

private struct SleepModeStepView: View {
    @ObservedObject var sleepVM: SleepViewModel
    @ObservedObject var alarmVM: AlarmViewModel
    let onExit: () -> Void
    @State private var showSleepMixEditor = false

    var body: some View {
        ZStack {
            gradientBackground
            VStack(spacing: 18) {
                Image(systemName: sleepVM.sleepUIMode == .alarmRinging ? "alarm.fill" : "moon.zzz.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(sleepVM.sleepUIMode == .alarmRinging ? .orange : .indigo)
                    .padding(.top, 24)
                    .shadow(color: (sleepVM.sleepUIMode == .alarmRinging ? Color.orange : Color.indigo).opacity(0.22), radius: 6, x: 0, y: 0)

                Text(sleepVM.sleepUIMode == .alarmRinging ? "Wake up" : "Sleep mode active")
                    .font(.title3.weight(.semibold))

                if sleepVM.sleepUIMode != .alarmRinging {
                    VStack(spacing: 6) {
                        Text("Alarm \(alarmVM.formattedWakeTime)")
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(alarmVM.smartWakeWindowExplanation)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.white.opacity(0.72))
                            .padding(.horizontal, 8)
                    }
                }

                Button {
                    showSleepMixEditor = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Микс: \(sleepVM.mixSummaryLabel())")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                        Text("Тот же экран, что при настройке звука: перетащите звуки на круг")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(sleepVM.sleepUIMode == .alarmRinging)
                .opacity(sleepVM.sleepUIMode == .alarmRinging ? 0.45 : 1)

                Text("Tone: \(Int(sleepVM.brainFrequencyHz)) Hz")
                    .foregroundStyle(Color.white.opacity(0.8))

                if sleepVM.sleepUIMode == .alarmRinging {
                    Text("Time's up — alarm is ringing")
                        .font(.title2.monospacedDigit())
                } else {
                    Text("Auto-off in \(formatted(seconds: sleepVM.remainingSeconds))")
                        .font(.title2.monospacedDigit())
                }

                if sleepVM.sleepUIMode == .alarmRinging {
                    if sleepVM.canSnoozeFromAlarm {
                        Button {
                            Task { await sleepVM.snoozeFromAlarm() }
                        } label: {
                            HStack {
                                Image(systemName: "moon.zzz.fill")
                                Text("Snooze \(AlarmBehaviorSettings.snoozeIntervalMinutes) min")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    PrimaryGradientButton(title: "I'm awake", systemImage: "sun.max.fill") {
                        sleepVM.dismissAlarmAndFinish()
                    }
                    .padding(.top, 8)
                } else {
                    PrimaryGradientButton(title: "Stop early", systemImage: "stop.fill") {
                        sleepVM.stopSleep()
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding()
        }
        .navigationTitle(sleepVM.sleepUIMode == .alarmRinging ? "Alarm" : "Sleep Mode")
        .navigationBarBackButtonHidden(true)
        .onAppear {
            sleepVM.syncSleepUIWhenViewAppears()
        }
        .navigationDestination(isPresented: $showSleepMixEditor) {
            SoundSetupStepView(sleepVM: sleepVM, alarmVM: alarmVM, isEditingActiveSleepSession: true) {
                // Уже спим — только возврат из редактора.
            }
            .onDisappear {
                showSleepMixEditor = false
            }
        }
        .onChange(of: sleepVM.isRunning) { _, running in
            if !running {
                onExit()
            }
        }
    }

    private func formatted(seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

private struct StatsStepView: View {
    @ObservedObject var sleepVM: SleepViewModel

    private var historyRows: [SleepSessionRecord] {
        Array(sleepVM.sessionHistory.prefix(20))
    }

    var body: some View {
        ZStack {
            gradientBackground
            List {
                Section {
                    if let latest = sleepVM.sessionHistory.first {
                        row("Last session", value: latest.startDate.formatted(date: .abbreviated, time: .omitted))
                        row("Sleep duration", value: formatDuration(minutes: latest.durationMinutes))
                        row("Activity level", value: "\(latest.activityLevel)%")
                    } else {
                        Text("No sessions yet. Finish a night with the alarm flow to see duration and activity here.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Overview")
                }

                Section {
                    if sleepVM.sessionHistory.isEmpty {
                        Text("Past nights stack up here — newest first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(historyRows) { session in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(session.startDate, format: .dateTime.month(.abbreviated).day())
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(formatDuration(minutes: session.durationMinutes))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                Text(session.recommendation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("History")
                } footer: {
                    if sleepVM.sessionHistory.count > 20 {
                        Text("Showing the 20 most recent sessions.")
                            .font(.caption2)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
        }
        .navigationTitle("Statistics")
    }

    private func formatDuration(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return "\(h) h" }
        return "\(h) h \(m) min"
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

private struct WakeResultView: View {
    let session: SleepSessionRecord
    let onContinue: () -> Void
    let onOpenStats: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                gradientBackground
                VStack(spacing: 16) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.yellow)
                        .padding(.top, 16)

                    Text("Good morning")
                        .font(.title2.bold())

                    Text("Sleep: \(session.durationMinutes / 60)h \(session.durationMinutes % 60)m")
                        .font(.headline)

                    Text(session.recommendation)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button("Continue") { onContinue() }
                            .buttonStyle(.bordered)
                        PrimaryGradientButton(title: "Open Stats") { onOpenStats() }
                    }
                    .controlSize(.large)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Wake Result")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private var gradientBackground: some View {
    LinearGradient(
        colors: [
            Color.black,
            Color(red: 0.06, green: 0.06, blue: 0.13),
            Color(red: 0.10, green: 0.08, blue: 0.18)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
}

private struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
        )
    }
}

private struct PrimaryGradientButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Spacer()
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.indigo, Color.purple.opacity(0.9)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
@MainActor
final class AlarmViewModel: ObservableObject {
    @Published var alarmTime: Date = Date()
    /// Дни недели: 1 = воскресенье … 7 = суббота (`Calendar.current`).
    @Published var alarmWeekdays: Set<Int> = AlarmBehaviorSettings.weekdayMask
    /// Минуты от начала суток по конкретному дню недели (1...7).
    @Published var alarmWeekdayTimesMinutes: [Int: Int] = AlarmBehaviorSettings.weekdayTimesMinutes

    @Published var alarmSound: AlarmSoundOption = .mechDigitalBuzzer
    @Published var wakeSoundMode: AlarmWakeSoundMode = .builtIn {
        didSet {
            AlarmWakeSoundModeStorage.set(wakeSoundMode)
            #if canImport(MediaPlayer) && os(iOS)
            if wakeSoundMode == .appleMusic {
                Task { await AlarmAppleMusicPlayback.requestAuthorizationsIfNeeded() }
            }
            #endif
        }
    }
    /// Подпись для карточки «Files» (копия из `AlarmLocalFileStorage`).
    @Published var localWakeFileDisplayName: String? = AlarmLocalFileStorage.displayName()
    /// M4a для уведомления на заблокированном экране готов (ваш звук, не запасной рингтон).
    @Published private(set) var lockScreenNotifyReady: Bool = AlarmLocalFileStorage.hasLockScreenNotifyClipReady()

    @Published private(set) var lastScheduledFireDate: Date?
    @Published private(set) var lastErrorMessage: String?
    private(set) var didRequestNotificationPermission = false

    private let alarmManager: AlarmManager
    private let alarmRingPlayer = AlarmRingPlayer()
    private static let savedAlarmSoundKey = "smartAlarm.selectedSound"
    private static let savedWakeHourKey = "smartAlarm.savedWakeHour"
    private static let savedWakeMinuteKey = "smartAlarm.savedWakeMinute"
    private static let savedWindowKey = "smartAlarm.savedWindow"
    /// Пользователь явно запланировал утро через отдельный экран — тогда при смене времени/таймзоны пересоздаём уведомление.
    private static let morningWakeScheduledKey = "smartAlarm.morningWakeScheduled"
    /// Последняя доставка уведомления, на которую уже подняли полный звук вне режима сна — не повторять при следующем `didBecomeActive`.
    private static let lastHandledWakeDeliveryDateKey = "smartAlarm.lastHandledWakeDeliveryDate"

    /// Сбросить «уже обработали этот пуш» — новое планирование или отбой будильника.
    private static func clearWakeDeliveryLedger() {
        UserDefaults.standard.removeObject(forKey: lastHandledWakeDeliveryDateKey)
    }

    /// Короткий анти-дубль в одном запуске процесса (willPresent + reconcile).
    private var lastStandaloneAlarmStartWallTime: Date?

    init(alarmManager: AlarmManager = AlarmManager()) {
        self.alarmManager = alarmManager
        if let raw = UserDefaults.standard.string(forKey: Self.savedAlarmSoundKey),
           let saved = AlarmSoundOption.migrated(from: raw) {
            alarmSound = saved
        }
        if let wake = Self.loadSavedWakeDate() {
            alarmTime = wake
        }
        alarmWeekdays = AlarmBehaviorSettings.weekdayMask
        alarmWeekdayTimesMinutes = AlarmBehaviorSettings.weekdayTimesMinutes
        wakeSoundMode = AlarmWakeSoundModeStorage.resolvedMode()
        localWakeFileDisplayName = AlarmLocalFileStorage.displayName()
        lockScreenNotifyReady = AlarmLocalFileStorage.hasLockScreenNotifyClipReady()
    }

    func refreshLockScreenReadiness() {
        lockScreenNotifyReady = AlarmLocalFileStorage.hasLockScreenNotifyClipReady()
    }

    func toggleAlarmWeekday(_ weekday: Int) {
        guard (1 ... 7).contains(weekday) else { return }
        var s = alarmWeekdays
        if s.contains(weekday) {
            s.remove(weekday)
            if s.isEmpty { s = Set(1 ... 7) }
        } else {
            s.insert(weekday)
        }
        alarmWeekdays = s
        AlarmBehaviorSettings.weekdayMask = s
    }

    func timeForWeekday(_ weekday: Int) -> Date {
        let calendar = Calendar.current
        let fallback = calendar.dateComponents([.hour, .minute], from: alarmTime)
        let fallbackMinutes = (fallback.hour ?? 7) * 60 + (fallback.minute ?? 0)
        let minutes = alarmWeekdayTimesMinutes[weekday] ?? fallbackMinutes
        let hour = min(23, max(0, minutes / 60))
        let minute = min(59, max(0, minutes % 60))
        var c = calendar.dateComponents([.year, .month, .day], from: Date())
        c.hour = hour
        c.minute = minute
        c.second = 0
        return calendar.date(from: c) ?? alarmTime
    }

    func setTime(_ date: Date, forWeekday weekday: Int) {
        guard (1 ... 7).contains(weekday) else { return }
        let hm = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minutes = min(1439, max(0, (hm.hour ?? 0) * 60 + (hm.minute ?? 0)))
        alarmWeekdayTimesMinutes[weekday] = minutes
        AlarmBehaviorSettings.weekdayTimesMinutes = alarmWeekdayTimesMinutes
    }

    func bindingForWeekdayTime(_ weekday: Int) -> Binding<Date> {
        Binding(
            get: { self.timeForWeekday(weekday) },
            set: { self.setTime($0, forWeekday: weekday) }
        )
    }

    func persistAlarmSound() {
        UserDefaults.standard.set(alarmSound.rawValue, forKey: Self.savedAlarmSoundKey)
    }

    func requestNotificationPermissionIfNeeded() async {
        guard !didRequestNotificationPermission else { return }
        didRequestNotificationPermission = true
        _ = await alarmManager.requestNotificationPermission()
    }

    /// Планирует утренний будильник (уведомления + follow-up). Вызывать перед `startSleep()` и при смене времени.
    func scheduleMorningAlarm(windowMinutes: Int) async {
        persistAlarmSound()
        persistWakeSettings(windowMinutes: windowMinutes)
        let wakeTime = nextOccurrence()
        let wakeWeekday = Calendar.current.component(.weekday, from: wakeTime)
        let selectedSound = alarmSound

        let granted = await alarmManager.requestNotificationPermission()
        guard granted else {
            lastErrorMessage = "Notifications are disabled. Please enable notifications for this app in Settings."
            lastScheduledFireDate = nil
            UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
            return
        }

        if wakeSoundMode == .localFile {
            guard AlarmLocalFileStorage.playbackURL() != nil else {
                lastErrorMessage = "Choose an audio file in Alarm sound first."
                lastScheduledFireDate = nil
                UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
                return
            }
        }

        let lockReady = await AlarmLocalFileStorage.prepareLockScreenNotifyClip()
        guard lockReady else {
            lastErrorMessage = "Your file isn’t ready for the lock screen yet. Open Alarm sound → Files, pick the track again, wait a moment, then try again. If it keeps failing, try M4A or a shorter MP3."
            lastScheduledFireDate = nil
            lockScreenNotifyReady = false
            UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
            return
        }
        lockScreenNotifyReady = true

        let effectiveWindow = effectiveWindowMinutes(baseWindow: windowMinutes)
        let date: Date?
        do {
                date = try await alarmManager.scheduleWakeUpNotification(
                    wakeTime: wakeTime,
                    windowMinutes: effectiveWindow,
                    sound: selectedSound,
                    followupCount: 1,
                    followupIntervalMinutes: 5,
                    weekdays: [wakeWeekday]
                )
        } catch {
            lastErrorMessage = "Failed to set alarm. Please try again."
            lastScheduledFireDate = nil
            UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
            return
        }
        lastScheduledFireDate = date
        UserDefaults.standard.set(date != nil, forKey: Self.morningWakeScheduledKey)
        Self.clearWakeDeliveryLedger()
        lastStandaloneAlarmStartWallTime = nil
        AlarmPlaybackAnchor.clear()
        if effectiveWindow == 0 {
            lastErrorMessage = "Less than 1 hour until wake: alarm at the exact time you set (Smart Wake off)."
        } else {
            lastErrorMessage = nil
        }
    }

    func setAlarm(windowMinutes: Int) {
        Task { await scheduleMorningAlarm(windowMinutes: windowMinutes) }
    }

    /// Re-schedule alarm if device time/timezone changed.
    func handleSignificantTimeChange() {
        guard UserDefaults.standard.bool(forKey: Self.morningWakeScheduledKey) else { return }
        guard let savedWake = Self.loadSavedWakeDate() else { return }
        let savedWindow = UserDefaults.standard.integer(forKey: Self.savedWindowKey)
        alarmTime = savedWake
        Task { await scheduleMorningAlarm(windowMinutes: max(0, savedWindow)) }
    }

    /// Smart Wake only when the next alarm is at least one hour away; otherwise exact time.
    var smartWakeExplanation: String {
        let next = nextOccurrence()
        let secondsUntil = next.timeIntervalSinceNow
        if secondsUntil < 3600 {
            return "Smart Wake needs at least 1 hour before wake time. Otherwise the alarm uses your exact time."
        }
        return "Smart Wake: when there’s at least 1 hour before wake, we ring around the middle of the window before your set time (not random)."
    }

    /// После того как пользователь подтвердил пробуждение (уведомления уже сняты в `SleepViewModel`).
    func syncMorningAlarmDismissedState() {
        lastScheduledFireDate = nil
        lastErrorMessage = nil
        UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
        Self.clearWakeDeliveryLedger()
        lastStandaloneAlarmStartWallTime = nil
        AlarmPlaybackAnchor.clear()
    }

    func clearScheduledMorningAlarm() {
        alarmManager.cancelScheduledMorningAlarm()
        syncMorningAlarmDismissedState()
    }

    /// Полноценный звук будильника при срабатывании уведомления, если режим сна не активен (в т.ч. трек Apple Music из медиатеки).
    func playAlarmFromNotification(notificationDeliveryDate: Date) {
        guard UserDefaults.standard.bool(forKey: Self.morningWakeScheduledKey) else { return }

        let now = Date()
        if let wall = lastStandaloneAlarmStartWallTime, now.timeIntervalSince(wall) < 1.8 {
            return
        }
        if let ts = UserDefaults.standard.object(forKey: Self.lastHandledWakeDeliveryDateKey) as? TimeInterval {
            let lastHandled = Date(timeIntervalSince1970: ts)
            if notificationDeliveryDate <= lastHandled.addingTimeInterval(3) {
                return
            }
        }

        lastStandaloneAlarmStartWallTime = now
        alarmManager.clearWakeRemindersAfterInAppAlarmHandling()
        if let raw = UserDefaults.standard.string(forKey: Self.savedAlarmSoundKey),
           let opt = AlarmSoundOption.migrated(from: raw) {
            alarmSound = opt
        }
        alarmRingPlayer.start(option: alarmSound)
        let prev = (UserDefaults.standard.object(forKey: Self.lastHandledWakeDeliveryDateKey) as? TimeInterval)
            .map { Date(timeIntervalSince1970: $0) }
        let mark = max(prev ?? notificationDeliveryDate, notificationDeliveryDate)
        UserDefaults.standard.set(mark.timeIntervalSince1970, forKey: Self.lastHandledWakeDeliveryDateKey)
    }

    func stopAlarmRingingFromNotification() {
        alarmRingPlayer.stop()
        AlarmPlaybackAnchor.clear()
        clearScheduledMorningAlarm()
    }

    var sleepDurationHours: Int {
        Int(nextOccurrence().timeIntervalSinceNow / 3600)
    }

    var sleepDurationMinutes: Int {
        let totalMinutes = Int(nextOccurrence().timeIntervalSinceNow / 60)
        return max(0, totalMinutes % 60)
    }

    var sleepDurationText: String {
        "\(sleepDurationHours) h \(sleepDurationMinutes) min"
    }

    /// Green 7–9 h; red if under 7 h; yellow if more than 9 h until wake.
    var sleepDurationColor: Color {
        let totalHours = Double(sleepDurationHours) + Double(sleepDurationMinutes) / 60
        if totalHours < 7 { return .red }
        if totalHours <= 9 { return .green }
        return .yellow
    }

    /// Время следующего срабатывания (сегодня или завтра) — для экрана «режим сна».
    var formattedWakeTime: String {
        nextOccurrence().formatted(date: .omitted, time: .shortened)
    }

    /// Текст про окно Smart Wake (после явного «Schedule morning alarm»).
    var smartWakeWindowExplanation: String {
        let next = nextOccurrence()
        let savedWindow = max(0, UserDefaults.standard.integer(forKey: Self.savedWindowKey))
        let windowM = effectiveWindowMinutes(baseWindow: savedWindow)
        let t = next.formatted(date: .omitted, time: .shortened)
        if windowM <= 0 {
            return "Exact alarm at \(t). Smart Wake is off (less than 1 hour until wake)."
        }
        let start = Calendar.current.date(byAdding: .minute, value: -windowM, to: next) ?? next
        let ts = start.formatted(date: .omitted, time: .shortened)
        return "Smart Wake: alarm is scheduled around the middle of \(ts)–\(t) (not random)."
    }

    private func effectiveWindowMinutes(baseWindow: Int) -> Int {
        let nextTarget = nextOccurrence()
        let secondsUntil = nextTarget.timeIntervalSinceNow
        if secondsUntil < 3600 {
            return 0
        }
        return max(0, baseWindow)
    }

    private func nextOccurrence(from now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let active = alarmWeekdays.isEmpty ? Set(1 ... 7) : alarmWeekdays
        let fallbackHM = calendar.dateComponents([.hour, .minute], from: alarmTime)
        let fallbackMinutes = (fallbackHM.hour ?? 7) * 60 + (fallbackHM.minute ?? 0)
        let startOfToday = calendar.startOfDay(for: now)
        var best: Date?
        for dayOffset in 0 ..< 14 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            let weekday = calendar.component(.weekday, from: dayStart)
            guard active.contains(weekday) else { continue }
            let minutes = alarmWeekdayTimesMinutes[weekday] ?? fallbackMinutes
            let hour = min(23, max(0, minutes / 60))
            let minute = min(59, max(0, minutes % 60))
            var c = calendar.dateComponents([.year, .month, .day], from: dayStart)
            c.hour = hour
            c.minute = minute
            c.second = 0
            guard let candidate = calendar.date(from: c), candidate > now else { continue }
            if best == nil || candidate < best! {
                best = candidate
            }
        }
        return best ?? now.addingTimeInterval(86_400)
    }

    private func persistWakeSettings(windowMinutes: Int) {
        let calendar = Calendar.current
        let hm = calendar.dateComponents([.hour, .minute], from: alarmTime)
        UserDefaults.standard.set(hm.hour ?? 7, forKey: Self.savedWakeHourKey)
        UserDefaults.standard.set(hm.minute ?? 0, forKey: Self.savedWakeMinuteKey)
        UserDefaults.standard.set(max(0, windowMinutes), forKey: Self.savedWindowKey)
        AlarmBehaviorSettings.weekdayMask = alarmWeekdays
        AlarmBehaviorSettings.weekdayTimesMinutes = alarmWeekdayTimesMinutes
    }

    private static func loadSavedWakeDate() -> Date? {
        guard UserDefaults.standard.object(forKey: savedWakeHourKey) != nil,
              UserDefaults.standard.object(forKey: savedWakeMinuteKey) != nil else {
            return nil
        }
        let hour = UserDefaults.standard.integer(forKey: savedWakeHourKey)
        let minute = UserDefaults.standard.integer(forKey: savedWakeMinuteKey)
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components)
    }
}

// MARK: - Открыли приложение без тапа по уведомлению (в фоне `smartAlarmDidFire` не приходит).
@MainActor
private func reconcileDeliveredWakeNotifications(sleepVM: SleepViewModel, alarmVM: AlarmViewModel) async {
    let notes = await withCheckedContinuation { (cont: CheckedContinuation<[UNNotification], Never>) in
        UNUserNotificationCenter.current().getDeliveredNotifications { cont.resume(returning: $0) }
    }
    func isWake(_ id: String) -> Bool {
        id == "smart_alarm_wakeup" || id == "smart_alarm_snooze" || id.hasPrefix("smart_alarm_wakeup_followup")
    }
    let wakeNotes = notes.filter { isWake($0.request.identifier) }
    guard !wakeNotes.isEmpty else { return }

    /// Полный звук только если уведомление недавнее; иначе только чистим центр уведомлений.
    let playWindowSeconds: TimeInterval = 75
    let now = Date()
    let freshEnoughToRing = wakeNotes.contains { now.timeIntervalSince($0.date) < playWindowSeconds }

    // Снять баннеры, follow-up и «залипший» pending основного wake до ветвления.
    AlarmManager().clearWakeRemindersAfterInAppAlarmHandling()

    if freshEnoughToRing {
        if let anchorDate = wakeNotes.map(\.date).min() {
            AlarmPlaybackAnchor.recordIfNeeded(anchorDate)
        }
        if sleepVM.isRunning && sleepVM.sleepUIMode == .sleeping {
            sleepVM.handleExternalAlarmFired()
        } else if sleepVM.isRunning && sleepVM.sleepUIMode == .alarmRinging {
            sleepVM.reassertAlarmPlaybackFromForegroundIfNeeded()
        } else if !sleepVM.isRunning, let maxDelivery = wakeNotes.map(\.date).max() {
            alarmVM.playAlarmFromNotification(notificationDeliveryDate: maxDelivery)
        }
    }
}
