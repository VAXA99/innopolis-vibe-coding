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
                SoundSetupStepView(sleepVM: sleepVM) {
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
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                sleepVM.syncSleepUIWhenViewAppears()
                Task { await reconcileDeliveredWakeNotifications(sleepVM: sleepVM, alarmVM: alarmVM) }
            }
            .onChange(of: scenePhase) { _, phase in
                sleepVM.handleScenePhaseChange(phase)
            }
            .onReceive(NotificationCenter.default.publisher(for: .smartAlarmDidFire)) { _ in
                AlarmPlaybackAnchor.recordIfNeeded(Date())
                if sleepVM.isRunning && sleepVM.sleepUIMode == .sleeping {
                    sleepVM.handleExternalAlarmFired()
                } else if !(sleepVM.isRunning && sleepVM.sleepUIMode == .alarmRinging) {
                    // Утренний будильник без режима сна: раньше играл только короткий WAV из уведомления, не трек из Apple Music.
                    alarmVM.playAlarmFromNotification()
                }
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
                        Text("Wake time")
                            .font(.headline)
                        DatePicker(
                            "",
                            selection: $alarmVM.alarmTime,
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                        .datePickerStyle(.wheel)
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
                                                    Text("Preparing lock-screen sound… open settings and tap Set Alarm again if needed.")
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

                    PrimaryGradientButton(title: "Set Alarm") {
                        alarmVM.persistAlarmSound()
                        alarmVM.setAlarm(windowMinutes: 30)
                        onNext()
                    }

                    if let scheduled = alarmVM.lastScheduledFireDate {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Next alarm: \(scheduled.formatted(date: .omitted, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(Color.white.opacity(0.9))
                        }
                    }

                    if alarmVM.lastScheduledFireDate != nil {
                        Button {
                            alarmVM.clearScheduledMorningAlarm()
                        } label: {
                            Text("Cancel scheduled alarm")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    }

                    if let error = alarmVM.lastErrorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red.opacity(0.95))
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
        .onDisappear {
            AlarmSoundPreview.stop()
            musicAlarmManager.stopPreview()
        }
    }
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
    let onStartSleep: () -> Void

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

            PrimaryGradientButton(title: "Go to Sleep", systemImage: "play.fill") {
                sleepVM.startSleep()
                onStartSleep()
            }
            .opacity(sleepVM.spatialPlacedSounds.isEmpty ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.45), value: sleepVM.spatialPlacedSounds.isEmpty)
            .disabled(sleepVM.spatialPlacedSounds.isEmpty)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .navigationTitle("Sound Setup")
        .navigationBarBackButtonHidden(true)
        .onAppear {
            sleepVM.spatialPlacedSounds = []
        }
        .onDisappear {
            sleepVM.stopSpatialPreview()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EmptyView()
            }
        }
    }
}

private struct SleepModeStepView: View {
    @ObservedObject var sleepVM: SleepViewModel
    @ObservedObject var alarmVM: AlarmViewModel
    let onExit: () -> Void

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

                Text("Mix: \(sleepVM.mixSummaryLabel())")
                    .foregroundStyle(.secondary)
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

    var body: some View {
        ZStack {
            gradientBackground
            List {
                Section("Today") {
                    if let latest = sleepVM.sessionHistory.first {
                        row("Sleep duration", value: "\(latest.durationMinutes / 60)h \(latest.durationMinutes % 60)m")
                        row("Activity level", value: "\(latest.activityLevel)%")
                    } else {
                        Text("No data yet. Start one sleep session tonight.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("History") {
                    if sleepVM.sessionHistory.isEmpty {
                        Text("Your sessions will appear here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sleepVM.sessionHistory) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.startDate, style: .date)
                                    .font(.subheadline.weight(.semibold))
                                Text("\(session.durationMinutes / 60)h \(session.durationMinutes % 60)m")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(session.recommendation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
        }
        .navigationTitle("Statistics")
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

    init(alarmManager: AlarmManager = AlarmManager()) {
        self.alarmManager = alarmManager
        if let raw = UserDefaults.standard.string(forKey: Self.savedAlarmSoundKey),
           let saved = AlarmSoundOption.migrated(from: raw) {
            alarmSound = saved
        }
        if let wake = Self.loadSavedWakeDate() {
            alarmTime = wake
        }
        wakeSoundMode = AlarmWakeSoundModeStorage.resolvedMode()
        localWakeFileDisplayName = AlarmLocalFileStorage.displayName()
        lockScreenNotifyReady = AlarmLocalFileStorage.hasLockScreenNotifyClipReady()
    }

    func refreshLockScreenReadiness() {
        lockScreenNotifyReady = AlarmLocalFileStorage.hasLockScreenNotifyClipReady()
    }

    func persistAlarmSound() {
        UserDefaults.standard.set(alarmSound.rawValue, forKey: Self.savedAlarmSoundKey)
    }

    func requestNotificationPermissionIfNeeded() async {
        guard !didRequestNotificationPermission else { return }
        didRequestNotificationPermission = true
        _ = await alarmManager.requestNotificationPermission()
    }

    func setAlarm(windowMinutes: Int) {
        persistAlarmSound()
        persistWakeSettings(windowMinutes: windowMinutes)
        let wakeTime = alarmTime
        let selectedSound = alarmSound
        Task { @MainActor in
            let granted = await alarmManager.requestNotificationPermission()
            guard granted else {
                self.lastErrorMessage = "Notifications are disabled. Please enable notifications for this app in Settings."
                self.lastScheduledFireDate = nil
                return
            }

            if self.wakeSoundMode == .localFile {
                guard AlarmLocalFileStorage.playbackURL() != nil else {
                    self.lastErrorMessage = "Choose an audio file in Alarm sound first."
                    self.lastScheduledFireDate = nil
                    return
                }
            }

            let lockReady = await AlarmLocalFileStorage.prepareLockScreenNotifyClip()
            guard lockReady else {
                self.lastErrorMessage = "Your file isn’t ready for the lock screen yet. Open Alarm sound → Files, pick the track again, wait a moment, then Set Alarm. If it keeps failing, try M4A or a shorter MP3."
                self.lastScheduledFireDate = nil
                self.lockScreenNotifyReady = false
                return
            }
            self.lockScreenNotifyReady = true

            let effectiveWindow = self.effectiveWindowMinutes(baseWindow: windowMinutes, wakeTime: wakeTime)
            let date: Date?
            do {
                date = try await alarmManager.scheduleWakeUpNotification(
                    wakeTime: wakeTime,
                    windowMinutes: effectiveWindow,
                    sound: selectedSound
                )
            } catch {
                self.lastErrorMessage = "Failed to set alarm. Please try again."
                self.lastScheduledFireDate = nil
                return
            }
            self.lastScheduledFireDate = date
            AlarmPlaybackAnchor.clear()
            if effectiveWindow == 0 {
                self.lastErrorMessage = "Less than 1 hour until wake time: Smart Wake is off — alarm fires at the exact time you set."
            } else {
                self.lastErrorMessage = nil
            }
        }
    }

    /// Re-schedule alarm if device time/timezone changed.
    func handleSignificantTimeChange() {
        guard let savedWake = Self.loadSavedWakeDate() else { return }
        let savedWindow = UserDefaults.standard.integer(forKey: Self.savedWindowKey)
        alarmTime = savedWake
        setAlarm(windowMinutes: max(0, savedWindow))
    }

    /// Smart Wake only when the next alarm is at least one hour away; otherwise exact time.
    var smartWakeExplanation: String {
        let next = nextOccurrence(of: alarmTime)
        let secondsUntil = next.timeIntervalSinceNow
        if secondsUntil < 3600 {
            return "Smart Wake needs at least 1 hour before wake time. Otherwise the alarm uses your exact time."
        }
        return "Smart Wake: random time within 30 minutes before your wake time, so you are not woken at the same minute every day."
    }

    func clearScheduledMorningAlarm() {
        alarmManager.cancelScheduledMorningAlarm()
        lastScheduledFireDate = nil
        lastErrorMessage = nil
        AlarmPlaybackAnchor.clear()
    }

    /// Полноценный звук будильника при срабатывании уведомления, если режим сна не активен (в т.ч. трек Apple Music из медиатеки).
    func playAlarmFromNotification() {
        if let raw = UserDefaults.standard.string(forKey: Self.savedAlarmSoundKey),
           let opt = AlarmSoundOption.migrated(from: raw) {
            alarmSound = opt
        }
        alarmRingPlayer.start(option: alarmSound)
    }

    func stopAlarmRingingFromNotification() {
        alarmRingPlayer.stop()
        AlarmPlaybackAnchor.clear()
    }

    var sleepDurationHours: Int {
        Int(nextOccurrence(of: alarmTime).timeIntervalSinceNow / 3600)
    }

    var sleepDurationMinutes: Int {
        let totalMinutes = Int(nextOccurrence(of: alarmTime).timeIntervalSinceNow / 60)
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
        nextOccurrence(of: alarmTime).formatted(date: .omitted, time: .shortened)
    }

    /// Текст про окно Smart Wake (как в шаге 1 после «Set Alarm»).
    var smartWakeWindowExplanation: String {
        let next = nextOccurrence(of: alarmTime)
        let savedWindow = max(0, UserDefaults.standard.integer(forKey: Self.savedWindowKey))
        let windowM = effectiveWindowMinutes(baseWindow: savedWindow, wakeTime: alarmTime)
        let t = next.formatted(date: .omitted, time: .shortened)
        if windowM <= 0 {
            return "Exact alarm at \(t). Smart Wake is off (less than 1 hour until wake)."
        }
        let start = Calendar.current.date(byAdding: .minute, value: -windowM, to: next) ?? next
        let ts = start.formatted(date: .omitted, time: .shortened)
        return "Smart Wake: we’ll try to wake you between \(ts) and \(t) when sleep is lighter."
    }

    private func effectiveWindowMinutes(baseWindow: Int, wakeTime: Date) -> Int {
        let nextTarget = nextOccurrence(of: wakeTime)
        let secondsUntil = nextTarget.timeIntervalSinceNow
        if secondsUntil < 3600 {
            return 0
        }
        return max(0, baseWindow)
    }

    private func nextOccurrence(of wakeTime: Date) -> Date {
        let calendar = Calendar.current
        let now = Date()
        let hm = calendar.dateComponents([.hour, .minute], from: wakeTime)
        guard let hour = hm.hour, let minute = hm.minute else { return now }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        var target = calendar.date(from: components) ?? now
        if target <= now {
            target = calendar.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return target
    }

    private func persistWakeSettings(windowMinutes: Int) {
        let calendar = Calendar.current
        let hm = calendar.dateComponents([.hour, .minute], from: alarmTime)
        UserDefaults.standard.set(hm.hour ?? 7, forKey: Self.savedWakeHourKey)
        UserDefaults.standard.set(hm.minute ?? 0, forKey: Self.savedWakeMinuteKey)
        UserDefaults.standard.set(max(0, windowMinutes), forKey: Self.savedWindowKey)
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
        id == "smart_alarm_wakeup" || id.hasPrefix("smart_alarm_wakeup_followup")
    }
    let wakeNotes = notes.filter { isWake($0.request.identifier) }
    guard !wakeNotes.isEmpty else { return }

    /// Полный звук будильника только если уведомление почти только что пришло (не при каждом следующем открытии приложения).
    let playWindowSeconds: TimeInterval = 180
    let now = Date()
    let freshEnoughToRing = wakeNotes.contains { now.timeIntervalSince($0.date) < playWindowSeconds }

    if freshEnoughToRing {
        if let anchorDate = wakeNotes.map(\.date).min() {
            AlarmPlaybackAnchor.recordIfNeeded(anchorDate)
        }
        if sleepVM.isRunning && sleepVM.sleepUIMode == .sleeping {
            sleepVM.handleExternalAlarmFired()
        } else if sleepVM.isRunning && sleepVM.sleepUIMode == .alarmRinging {
            sleepVM.reassertAlarmPlaybackFromForegroundIfNeeded()
        } else {
            alarmVM.playAlarmFromNotification()
        }
    }

    // Убрать из центра — иначе при каждом открытии приложения снова вызывался бы полный звук MP3.
    let ids = Array(Set(wakeNotes.map(\.request.identifier)))
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
}
