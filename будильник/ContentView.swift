// ContentView.swift
import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var alarmVM = AlarmViewModel()
    @StateObject private var sleepVM = SleepViewModel()

    @State private var showSoundStep = false
    @State private var showSleepMode = false
    @State private var showStats = false
    @State private var showWakeResult = false

    var body: some View {
        NavigationStack {
            AlarmSetupStepView(
                alarmVM: alarmVM,
                onNext: { showSoundStep = true },
                onOpenStats: { showStats = true }
            )
            .navigationDestination(isPresented: $showSoundStep) {
                SoundSetupStepView(sleepVM: sleepVM) {
                    showSleepMode = true
                }
            }
            .navigationDestination(isPresented: $showSleepMode) {
                SleepModeStepView(sleepVM: sleepVM) {
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
        }
    }
}

private struct AlarmSetupStepView: View {
    @ObservedObject var alarmVM: AlarmViewModel
    let onNext: () -> Void
    let onOpenStats: () -> Void

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

                    PrimaryGradientButton(title: "Set Alarm") {
                        alarmVM.setAlarm(windowMinutes: 30)
                        onNext()
                    }
                }
                .padding(20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
    let onExit: () -> Void

    var body: some View {
        ZStack {
            gradientBackground
            VStack(spacing: 18) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.indigo)
                    .padding(.top, 24)
                    .symbolEffect(.pulse)

                Text("Sleep mode active")
                    .font(.title3.weight(.semibold))

                Text("Mix: \(sleepVM.mixSummaryLabel())")
                    .foregroundStyle(.secondary)
                Text("Tone: \(Int(sleepVM.brainFrequencyHz)) Hz")
                    .foregroundStyle(Color.white.opacity(0.8))

                Text("Auto-off in \(formatted(seconds: sleepVM.remainingSeconds))")
                    .font(.title2.monospacedDigit())

                PrimaryGradientButton(title: "Stop Early") {
                    sleepVM.stopSleep()
                    onExit()
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding()
        }
        .navigationTitle("Sleep Mode")
        .navigationBarBackButtonHidden(true)
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
    private(set) var didRequestNotificationPermission = false

    private let alarmManager: AlarmManager

    init(alarmManager: AlarmManager = AlarmManager()) {
        self.alarmManager = alarmManager
    }

    func requestNotificationPermissionIfNeeded() async {
        guard !didRequestNotificationPermission else { return }
        didRequestNotificationPermission = true
        _ = await alarmManager.requestNotificationPermission()
    }

    func setAlarm(windowMinutes: Int) {
        let wakeTime = alarmTime
        Task {
            _ = try? await alarmManager.scheduleWakeUpNotification(wakeTime: wakeTime, windowMinutes: windowMinutes)
        }
    }
}
