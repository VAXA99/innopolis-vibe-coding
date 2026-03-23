// ContentView.swift
import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var alarmVM = AlarmViewModel()
    @StateObject private var sleepVM = SleepViewModel()

    private let timerOptions = [10, 15, 30]

    var body: some View {
        NavigationStack {
            Form {
                Section("Alarm") {
                    DatePicker(
                        "Wake Time",
                        selection: $alarmVM.alarmTime,
                        displayedComponents: [.hourAndMinute]
                    )
                    .datePickerStyle(.wheel)

                    Button("Set Alarm") {
                        alarmVM.setAlarm()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section("Sleep Mode") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(SleepSound.allCases) { sound in
                                let selected = sleepVM.selectedSound == sound
                                Button {
                                    sleepVM.selectedSound = sound
                                } label: {
                                    VStack(spacing: 8) {
                                        Image(systemName: sound.iconName)
                                            .font(.system(size: 22, weight: .semibold))
                                        Text(sound.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(selected ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(sleepVM.isRunning)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 92)

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Volume")
                                Spacer()
                                Text("\(Int(sleepVM.volume * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $sleepVM.volume, in: 0...1)
                                .onChange(of: sleepVM.volume) { _ in
                                    sleepVM.applySoundSettingsIfRunning()
                                }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Softness")
                                Spacer()
                                Text("\(Int(sleepVM.softness * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $sleepVM.softness, in: 0...1)
                                .onChange(of: sleepVM.softness) { _ in
                                    sleepVM.applySoundSettingsIfRunning()
                                }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Space")
                                Spacer()
                                Text("\(Int(sleepVM.space * 100))%")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $sleepVM.space, in: 0...1)
                                .onChange(of: sleepVM.space) { _ in
                                    sleepVM.applySoundSettingsIfRunning()
                                }
                        }
                    }

                    Picker("Timer", selection: $sleepVM.timerMinutes) {
                        ForEach(timerOptions, id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(sleepVM.isRunning)

                    Button(sleepVM.isRunning ? "Stop" : "Start Sleep") {
                        if sleepVM.isRunning {
                            sleepVM.stopSleep()
                        } else {
                            sleepVM.startSleep()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Smart Alarm")
            .task {
                await alarmVM.requestNotificationPermissionIfNeeded()
            }
        }
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

    func setAlarm() {
        let wakeTime = alarmTime
        Task {
            _ = try? await alarmManager.scheduleWakeUpNotification(wakeTime: wakeTime, windowMinutes: 30)
        }
    }
}
