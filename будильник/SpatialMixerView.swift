import SwiftUI
import UIKit

private struct MixerCircleFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Binarium-style spatial mixer: drag from the tray onto the ring; closer to center = louder.
struct SpatialMixerView: View {
    @ObservedObject var sleepVM: SleepViewModel
    /// Reserve space when a parent overlays a bottom button (e.g. "Go to Sleep").
    var bottomExtraPadding: CGFloat = 0
    @State private var circleGlobalFrame: CGRect = .zero
    @State private var showSettingsSheet = false
    @State private var ringPulse: CGFloat = 1
    /// Drag preview positions (not written to ViewModel every frame — keeps UI smooth).
    @State private var dragUnitById: [UUID: CGPoint] = [:]

    var body: some View {
        ZStack {
            StarfieldBackgroundView()
            mixerGradientBackground.opacity(0.55)

            VStack(alignment: .leading, spacing: 0) {
                header
                mixerCanvas
                    .frame(maxHeight: .infinity)
                bottomTray
            }
            .padding(.bottom, bottomExtraPadding)
        }
        .sheet(isPresented: $showSettingsSheet) {
            combinedSettingsSheet
                .presentationDetents([.large])
                .preferredColorScheme(.dark)
        }
        .onChange(of: sleepVM.softness) { _, _ in sleepVM.applySpatialMasterEffects() }
        .onChange(of: sleepVM.space) { _, _ in sleepVM.applySpatialMasterEffects() }
        .onChange(of: sleepVM.brainFrequencyHz) { _, _ in sleepVM.applySpatialMasterEffects() }
        .onAppear {
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                ringPulse = 1.04
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("sleep mix")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Tone · \(Int(sleepVM.brainFrequencyHz)) Hz")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            Spacer()
            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(10)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var mixerCanvas: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side * 0.42
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let t = CGFloat(ring + 1) / 3.2
                    Circle()
                        .stroke(Color.white.opacity(0.14 - Double(ring) * 0.03), lineWidth: 1)
                        .frame(width: radius * 2 * t * ringPulse, height: radius * 2 * t * ringPulse)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .frame(width: 14, height: 18)
                    Rectangle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 2, height: 14)
                }
                .position(center)

                ForEach(sleepVM.spatialPlacedSounds) { item in
                    let u = dragUnitById[item.id] ?? item.unitOffset
                    let pos = screenPoint(for: u, center: center, radius: radius)
                    soundNode(item: item)
                        .position(pos)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: MixerCircleFrameKey.self, value: g.frame(in: .global))
                }
            )
            .onPreferenceChange(MixerCircleFrameKey.self) { circleGlobalFrame = $0 }
        }
    }

    private func screenPoint(for unitOffset: CGPoint, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + CGFloat(unitOffset.x) * radius, y: center.y + CGFloat(unitOffset.y) * radius)
    }

    private func effectiveCircleFrame() -> CGRect {
        if circleGlobalFrame.width > 2 { return circleGlobalFrame }
        let b = UIScreen.main.bounds
        return CGRect(x: b.minX, y: b.minY + b.height * 0.18, width: b.width, height: b.height * 0.48)
    }

    /// Map global finger to normalized coords (center = 0, ring edge ≈ 1). Allows hypot > 1 while dragging off-ring.
    private func rawUnitOffsetFromGlobal(_ global: CGPoint) -> CGPoint {
        let f = effectiveCircleFrame()
        let cx = f.midX
        let cy = f.midY
        let r = max(1, min(f.width, f.height) * 0.42)
        let dx = global.x - cx
        let dy = global.y - cy
        return CGPoint(x: Double(dx / r), y: Double(dy / r))
    }

    /// Drop from tray: only when finger is over the ring (small slop).
    private func unitOffsetFromGlobalForDrop(_ global: CGPoint) -> CGPoint? {
        let f = effectiveCircleFrame()
        let cx = f.midX
        let cy = f.midY
        let r = min(f.width, f.height) * 0.42
        let dx = global.x - cx
        let dy = global.y - cy
        guard hypot(dx, dy) <= r + 12 else { return nil }
        let u = rawUnitOffsetFromGlobal(global)
        return SpatialPlacedSound.clampedToUnitCircle(u)
    }

    private func isDropBelowPlatform(_ global: CGPoint) -> Bool {
        let f = effectiveCircleFrame()
        return global.y > f.maxY + 8
    }

    private func soundNode(item: SpatialPlacedSound) -> some View {
        let icon = item.sound.iconName
        return ZStack {
            Circle()
                .fill(Color.black.opacity(0.6))
                .frame(width: 50, height: 50)
                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let u = rawUnitOffsetFromGlobal(value.location)
                    var next = dragUnitById
                    next[item.id] = u
                    dragUnitById = next
                    sleepVM.updateSpatialMixVolumesWithOverrides(next)
                }
                .onEnded { value in
                    let u = rawUnitOffsetFromGlobal(value.location)
                    let d = hypot(u.x, u.y)
                    dragUnitById.removeValue(forKey: item.id)
                    if d > 1.02 || isDropBelowPlatform(value.location) {
                        sleepVM.removeSpatialNode(id: item.id)
                    } else {
                        sleepVM.commitSpatialNode(id: item.id, unitOffset: u)
                        sleepVM.updateSpatialMixVolumes()
                    }
                }
        )
        .frame(width: 56, height: 56)
        .shadow(color: Color.indigo.opacity(0.4), radius: 10, x: 0, y: 0)
    }

    private var bottomTray: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.55), Color.white.opacity(0.12)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 3)
                .padding(.horizontal, 40)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(SleepSound.allCases) { sound in
                        trayChip(sound)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(minHeight: 104)

            Text("Drag onto the ring • one layer per sound • drag off or below to remove")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .padding(.top, 10)
        .background(
            ZStack {
                Color.black.opacity(0.62)
                LinearGradient(
                    colors: [Color.black.opacity(0.9), Color(red: 0.08, green: 0.06, blue: 0.14)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func trayChip(_ sound: SleepSound) -> some View {
        let onPlatform = sleepVM.spatialPlacedSounds.contains(where: { $0.sound == sound })
        return VStack(spacing: 6) {
            Image(systemName: sound.iconName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white)
                .symbolRenderingMode(.hierarchical)
            Text(shortLabel(for: sound))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(onPlatform ? 1 : 0.88))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(onPlatform ? 0.18 : 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(onPlatform ? Color.cyan.opacity(0.45) : Color.white.opacity(0.22), lineWidth: 1)
        )
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onEnded { value in
                    if let u = unitOffsetFromGlobalForDrop(value.location) {
                        sleepVM.setSpatialSoundAt(sound, unitOffset: u)
                    }
                }
        )
    }

    private func shortLabel(for sound: SleepSound) -> String {
        switch sound {
        case .rain: return "rain"
        case .fire: return "bells"
        case .softPad: return "vocal"
        case .brook: return "water"
        case .cosmicDream: return "plane"
        }
    }

    private var combinedSettingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sectionTitle("Sleep timer")
                    Text("Stops the soundscape when time is up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Minutes", selection: $sleepVM.timerMinutes) {
                        ForEach([10, 15, 20, 25, 30], id: \.self) { m in
                            Text("\(m) min").tag(m)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 120)

                    Divider().opacity(0.3)

                    sectionTitle("Space & softness")
                    Text("Softness tames brightness; space widens the stereo image (no separate reverb bus on this mix).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliderRow("Softness", value: $sleepVM.softness)
                    sliderRow("Space (width)", value: $sleepVM.space)

                    Divider().opacity(0.3)

                    sectionTitle("Tone (Hz blend)")
                    Text("Blends with softness to nudge the overall tone — presets below are starting points only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quick presets")
                            .font(.subheadline.weight(.semibold))
                        VStack(spacing: 8) {
                            ForEach(SleepTonePreset.allCases) { preset in
                                Button {
                                    sleepVM.applySleepTonePreset(preset)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(preset.title)
                                                .font(.subheadline.weight(.semibold))
                                            Text(preset.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.right.circle.fill")
                                            .foregroundStyle(Color.cyan.opacity(0.7))
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.white.opacity(0.1))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack {
                        Text("Blend")
                        Spacer()
                        Text("\(Int(sleepVM.brainFrequencyHz)) Hz")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $sleepVM.brainFrequencyHz, in: 120...600, step: 1)
                }
                .padding(20)
            }
            .background(mixerGradientBackground)
            .navigationTitle("Sound setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showSettingsSheet = false }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(.white)
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%")
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
        .foregroundStyle(.white)
    }
}

private struct StarfieldBackgroundView: View {
    var body: some View {
        Canvas { context, size in
            for i in 0..<100 {
                let x = CGFloat((i * 47 + i * i) % 100) / 100 * size.width
                let y = CGFloat((i * 91) % 100) / 100 * size.height
                let a = 0.12 + CGFloat(i % 7) * 0.06
                let p = Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2))
                context.fill(p, with: .color(Color.white.opacity(a)))
            }
        }
        .ignoresSafeArea()
    }
}

private var mixerGradientBackground: some View {
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
