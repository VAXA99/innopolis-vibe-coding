import SwiftUI

#if canImport(UIKit) && os(iOS)
import AudioToolbox
import UIKit
#endif

/// Площадка «свой рисунок» вибрации: статус записи, старт/стоп, после стопа — сразу прослушивание.
struct AlarmVibrationCustomPatternPad: View {
    @Binding var samples: [AlarmVibrationSettings.PatternSample]

    @State private var isRecording = false
    @State private var fingerDown = false
    /// База таймлайна на момент «Начать запись» (дорисовка продолжает с конца).
    @State private var segmentTimelineBase: TimeInterval = 0
    @State private var epochStart: Date?
    @State private var holdStart: Date?
    @State private var lastEmitAt: Date?

    private let maxRecordSeconds: TimeInterval = 10
    private let tickInterval: TimeInterval = 0.085

    private var statusTitle: String {
        if isRecording {
            return fingerDown ? "Идёт запись — ведите палец" : "Идёт запись — коснитесь площадки"
        }
        return "Запись выключена"
    }

    private var statusDetail: String {
        isRecording
            ? "Нажмите «Стоп записи», когда закончили — рисунок сразу проиграется."
            : "Нажмите «Начать запись», затем рисуйте на площадке."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.red.opacity(0.25) : Color.white.opacity(0.08))
                        .frame(width: 40, height: 40)
                    Image(systemName: isRecording ? "record.circle" : "pause.circle")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isRecording ? Color.red : Color.white.opacity(0.45))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    beginRecording()
                } label: {
                    Label("Начать запись", systemImage: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(isRecording)

                Button {
                    stopRecordingAndPreview()
                } label: {
                    Label("Стоп записи", systemImage: "stop.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(!isRecording)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.07),
                                Color.indigo.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: fingerDown
                                        ? [Color.cyan.opacity(0.9), Color.blue.opacity(0.5)]
                                        : [Color.white.opacity(0.22), Color.white.opacity(0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: fingerDown ? 2.5 : 1
                            )
                    )
                    .frame(height: 168)

                VStack(spacing: 8) {
                    Image(systemName: "hand.draw.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.white.opacity(0.85), Color.cyan.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(
                        isRecording
                            ? (fingerDown ? "Удерживайте или ведите…" : "Коснитесь площадки")
                            : "Сначала «Начать запись»"
                    )
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary.opacity(0.9))
                }
                .padding()
            }
            .contentShape(Rectangle())
            .opacity(isRecording ? 1 : 0.55)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isRecording else { return }
                        let now = Date()
                        if epochStart == nil {
                            epochStart = now
                        }
                        if !fingerDown {
                            fingerDown = true
                            holdStart = now
                            lastEmitAt = nil
                        }
                        guard let e0 = epochStart, let h0 = holdStart else { return }
                        let tRel = segmentTimelineBase + now.timeIntervalSince(e0)
                        guard tRel <= maxRecordSeconds else { return }
                        if let last = lastEmitAt, now.timeIntervalSince(last) < tickInterval { return }
                        lastEmitAt = now
                        let hold = now.timeIntervalSince(h0)
                        let intensity = Float(min(1.0, 0.36 + hold * 1.15))
                        samples.append(
                            AlarmVibrationSettings.PatternSample(offset: tRel, intensity: intensity, systemBuzz: true)
                        )
                        if samples.count > 140 {
                            samples.removeFirst(samples.count - 140)
                        }
                        #if canImport(UIKit) && os(iOS)
                        let gen = UIImpactFeedbackGenerator(style: .heavy)
                        gen.prepare()
                        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
                        gen.impactOccurred(intensity: CGFloat(intensity))
                        #endif
                    }
                    .onEnded { _ in
                        guard isRecording else { return }
                        fingerDown = false
                        holdStart = nil
                        lastEmitAt = nil
                    }
            )

            HStack(spacing: 10) {
                Button {
                    clearPattern()
                } label: {
                    Label("Очистить", systemImage: "trash")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .disabled(isRecording || samples.isEmpty)

                Button {
                    let norm = AlarmVibrationSettings.normalizeCustomPatternTimeline(samples)
                    AlarmVibrationSettings.playCustomPatternPreview(samples: norm)
                } label: {
                    Label("Прослушать", systemImage: "waveform")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(samples.isEmpty)
            }

            HStack {
                Text("Сэмплов: \(samples.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("до \(Int(maxRecordSeconds)) с")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.2), radius: 12, y: 4)
        )
    }

    private func beginRecording() {
        segmentTimelineBase = samples.map(\.offset).max() ?? 0
        epochStart = nil
        fingerDown = false
        holdStart = nil
        lastEmitAt = nil
        isRecording = true
    }

    private func stopRecordingAndPreview() {
        isRecording = false
        fingerDown = false
        holdStart = nil
        lastEmitAt = nil
        epochStart = nil
        samples = AlarmVibrationSettings.normalizeCustomPatternTimeline(samples)
        guard !samples.isEmpty else { return }
        AlarmVibrationSettings.playCustomPatternPreview(samples: samples)
    }

    private func clearPattern() {
        samples = []
        segmentTimelineBase = 0
        epochStart = nil
        fingerDown = false
        holdStart = nil
        lastEmitAt = nil
        isRecording = false
    }
}
