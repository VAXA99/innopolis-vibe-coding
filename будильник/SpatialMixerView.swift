import SwiftUI
import UIKit

private struct MixerCircleFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct TrayChipFrameKey: PreferenceKey {
    static var defaultValue: [SleepSound: CGRect] = [:]
    static func reduce(value: inout [SleepSound: CGRect], nextValue: () -> [SleepSound: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Binarium-style spatial mixer: drag from the tray onto the ring; closer to center = louder.
struct SpatialMixerView: View {
    @ObservedObject var sleepVM: SleepViewModel
    /// Reserve space when a parent overlays a bottom button (e.g. "Go to Sleep").
    var bottomExtraPadding: CGFloat = 0
    /// Размер круглой иконки в ленте и на платформе.
    private let traySlotSize: CGFloat = 56
    /// Ширина колонки: иконка + подпись (как в референсе).
    private let trayColumnWidth: CGFloat = 68
    /// Высота слота: иконка + подпись.
    private let trayColumnHeight: CGFloat = 82
    @State private var circleGlobalFrame: CGRect = .zero
    @State private var showSettingsSheet = false
    @State private var ringPulse: CGFloat = 1
    /// Drag preview positions (not written to ViewModel every frame — keeps UI smooth).
    @State private var dragUnitById: [UUID: CGPoint] = [:]
    @State private var trayDrag: TrayDragState?
    @State private var trayChipFrames: [SleepSound: CGRect] = [:]
    @State private var hiddenTraySounds: Set<SleepSound> = []
    @State private var returningTokens: [ReturningToken] = []
    @State private var trayDragPrevSample: (CGPoint, TimeInterval)?
    @State private var trayDragLastSample: (CGPoint, TimeInterval)?
    @State private var platformDragPrevSample: (CGPoint, TimeInterval)?
    @State private var platformDragLastSample: (CGPoint, TimeInterval)?

    private struct TrayDragState {
        let sound: SleepSound
        var globalLocation: CGPoint
        /// Кадр чипа в момент захвата — чтобы вернуть палец «в тот же слот», даже когда чип уже убран из ленты.
        let originGlobalFrame: CGRect
    }

    private struct ReturningToken: Identifiable {
        let id: UUID
        let sound: SleepSound
        var globalLocation: CGPoint
    }

    struct DividerMixDescriptor: Equatable {
        let baseAmplitude: Double
        let speed: Double
        let roughness: Double
        let glow: Double
        let motionA: Double
        let motionB: Double
        let interaction: Double
        let signature: Double
    }

    var body: some View {
        GeometryReader { geo in
            let rootFrame = geo.frame(in: .global)
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

                if let trayDrag {
                    trayDragProxy(sound: trayDrag.sound, globalLocation: trayDrag.globalLocation)
                        .scaleEffect(1.04)
                        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
                        .position(
                            x: trayDrag.globalLocation.x - rootFrame.minX,
                            y: trayDrag.globalLocation.y - rootFrame.minY
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                ForEach(returningTokens) { token in
                    mixerTokenIcon(token.sound)
                        .scaleEffect(0.98)
                        .opacity(0.95)
                        .position(
                            x: token.globalLocation.x - rootFrame.minX,
                            y: token.globalLocation.y - rootFrame.minY
                        )
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onPreferenceChange(TrayChipFrameKey.self) { trayChipFrames = $0 }
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

    /// Маркер центра платформы (всегда на экране).
    private var platformCenterMarker: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.white.opacity(0.78))
                .frame(width: 14, height: 18)
            Rectangle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 2, height: 14)
        }
    }

    /// Кольца платформы: только когда уже есть слой на круге или идёт перетаскивание снизу.
    private var showMixerPlatformChrome: Bool {
        trayDrag != nil || !sleepVM.spatialPlacedSounds.isEmpty
    }

    private var mixerCanvas: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side * 0.42
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                /// Центр платформы всегда виден — ориентир, даже когда пусто.
                platformCenterMarker
                    .position(center)

                Group {
                    if showMixerPlatformChrome {
                        ForEach(0..<3, id: \.self) { ring in
                            let t = CGFloat(ring + 1) / 3.2
                            let w = 1.0 + CGFloat(ring) * 0.35
                            let breathe = ringPulse + CGFloat(ring) * 0.014
                            Circle()
                                .stroke(
                                    AngularGradient(
                                        colors: [
                                            Color.white.opacity(0.34 - Double(ring) * 0.05),
                                            Color.cyan.opacity(0.18 - Double(ring) * 0.03),
                                            Color.white.opacity(0.12),
                                            Color.white.opacity(0.28 - Double(ring) * 0.04)
                                        ],
                                        center: .center,
                                        angle: .degrees(Double(ring) * 40)
                                    ),
                                    lineWidth: w
                                )
                                .frame(width: radius * 2 * t * breathe, height: radius * 2 * t * breathe)
                                .shadow(color: Color.white.opacity(0.06 + Double(ring) * 0.03), radius: 5 + CGFloat(ring) * 2, x: 0, y: 0)
                        }
                    }
                }
                .animation(.easeOut(duration: 0.28), value: showMixerPlatformChrome)

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

    /// Насколько палец «вошёл» в зону платформы (0…1) — для кольца на прокси при перетаскивании.
    private func platformProximityProgress(for global: CGPoint) -> CGFloat {
        let f = effectiveCircleFrame()
        guard f.width > 2, f.height > 2 else { return 0 }
        let cx = f.midX
        let cy = f.midY
        let rDrop = min(f.width, f.height) * 0.42
        let dist = hypot(global.x - cx, global.y - cy)
        let edgeSlop: CGFloat = 14
        if dist <= rDrop + edgeSlop { return 1 }
        let band: CGFloat = 150
        let farEdge = rDrop + edgeSlop + band
        if dist >= farEdge { return 0 }
        return CGFloat((farEdge - dist) / band)
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

    private var slotUnitOffsets: [CGPoint] {
        let outer = stride(from: 0.0, to: 360.0, by: 45.0).map { deg -> CGPoint in
            let a = deg * .pi / 180
            return CGPoint(x: cos(a) * 0.72, y: sin(a) * 0.72)
        }
        let inner = stride(from: 22.5, to: 360.0, by: 90.0).map { deg -> CGPoint in
            let a = deg * .pi / 180
            return CGPoint(x: cos(a) * 0.42, y: sin(a) * 0.42)
        }
        return outer + inner
    }

    private func nearestSlotIndex(to point: CGPoint) -> Int {
        slotUnitOffsets.enumerated().min { lhs, rhs in
            hypot(lhs.element.x - point.x, lhs.element.y - point.y) <
                hypot(rhs.element.x - point.x, rhs.element.y - point.y)
        }?.offset ?? 0
    }

    private func snappedUnitOffsetForDrop(_ global: CGPoint, sound: SleepSound) -> CGPoint? {
        guard unitOffsetFromGlobalForDrop(global) != nil else { return nil }
        let raw = SpatialPlacedSound.clampedToUnitCircle(rawUnitOffsetFromGlobal(global))

        var occupiedSlotIndices = Set<Int>()
        for item in sleepVM.spatialPlacedSounds where item.sound != sound {
            occupiedSlotIndices.insert(nearestSlotIndex(to: item.unitOffset))
        }

        let available = slotUnitOffsets.enumerated().filter { !occupiedSlotIndices.contains($0.offset) }
        if let best = available.min(by: { lhs, rhs in
            hypot(lhs.element.x - raw.x, lhs.element.y - raw.y) <
                hypot(rhs.element.x - raw.x, rhs.element.y - raw.y)
        }) {
            return best.element
        }
        return raw
    }

    private func isDropBelowPlatform(_ global: CGPoint) -> Bool {
        let f = effectiveCircleFrame()
        return global.y > f.maxY + 8
    }

    /// Свободная иконка без круга (как в референсе): только SF Symbol.
    private func mixerTokenIcon(_ sound: SleepSound) -> some View {
        Image(systemName: sound.iconName)
            .font(.system(size: 26, weight: .regular))
            .foregroundStyle(
                LinearGradient(
                    colors: [Color.white, Color.white.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .symbolRenderingMode(.hierarchical)
            .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 2)
            .frame(width: traySlotSize, height: traySlotSize)
            .contentShape(Rectangle())
    }

    private func isSoundInReturnFlight(_ sound: SleepSound) -> Bool {
        returningTokens.contains { $0.sound == sound }
    }

    /// Прокси при перетаскивании: без кольца-прогресса, только сама иконка.
    private func trayDragProxy(sound: SleepSound, globalLocation: CGPoint) -> some View {
        let p = platformProximityProgress(for: globalLocation)
        return mixerTokenIcon(sound)
            .scaleEffect(0.94)
            .opacity(0.78 + 0.22 * Double(p))
    }

    private func trayIconIdleOffset(sound: SleepSound, date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let phase = Double(SleepSound.allCases.firstIndex(of: sound) ?? 0) * 0.7
        return CGFloat(sin(t * 1.8 + phase)) * 2.8
    }

    private func trayCaptionLabel(_ sound: SleepSound) -> String {
        switch sound {
        case .rain: return "rain"
        case .fire: return "bells"
        case .softPad: return "vocal"
        case .brook: return "water"
        case .cosmicDream: return "plane"
        }
    }

    /// Пустой слот: звук на платформе — без кругов у «иконки», только лёгкий маркер слота.
    private func traySlotPlaceholder(sound: SleepSound) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .frame(width: 30, height: 30)
                .frame(width: traySlotSize, height: traySlotSize)
            Text(trayCaptionLabel(sound))
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.28))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: trayColumnWidth, height: trayColumnHeight, alignment: .top)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: TrayChipFrameKey.self, value: [sound: g.frame(in: .global)])
            }
        )
    }

    private func soundNode(item: SpatialPlacedSound) -> some View {
        mixerTokenIcon(item.sound)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let t = ProcessInfo.processInfo.systemUptime
                    platformDragPrevSample = platformDragLastSample
                    platformDragLastSample = (value.location, t)
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
                    let platformSpeed = platformFingerSpeedPointsPerSecond()
                    platformDragPrevSample = nil
                    platformDragLastSample = nil
                    if d > 1.02 || isDropBelowPlatform(value.location) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                            sleepVM.removeSpatialNode(id: item.id)
                        }
                        animateReturnToTray(sound: item.sound, startGlobal: value.location, speed: platformSpeed)
                    } else {
                        sleepVM.commitSpatialNode(id: item.id, unitOffset: u)
                        sleepVM.updateSpatialMixVolumes()
                    }
                }
        )
        .frame(width: traySlotSize, height: traySlotSize)
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
    }

    private var bottomTray: some View {
        VStack(spacing: 10) {
            SnakeDividerView()
                .frame(height: 30)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: trayDrag != nil)) { context in
                HStack(spacing: 8) {
                    ForEach(SleepSound.allCases) { sound in
                        let onPlatform = sleepVM.spatialPlacedSounds.contains(where: { $0.sound == sound })
                        Group {
                            if onPlatform {
                                trayEmptySlot(sound: sound)
                            } else {
                                trayChip(sound, timeline: context.date)
                            }
                        }
                            .frame(width: trayColumnWidth, height: trayColumnHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)

            Text("Drag onto the ring • one layer per sound • drag off or below to remove")
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .padding(.top, 10)
        .background(Color.clear)
    }

    private func trayEmptySlot(sound: SleepSound) -> some View {
        Color.clear
            .frame(width: trayColumnWidth, height: trayColumnHeight)
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: TrayChipFrameKey.self, value: [sound: g.frame(in: .global)])
                }
            )
    }

    private func trayChip(_ sound: SleepSound, timeline: Date) -> some View {
        let isHidden = hiddenTraySounds.contains(sound)
        let op = trayChipListOpacity(isHidden: isHidden, sound: sound)
        let idle = trayDrag == nil && !isSoundInReturnFlight(sound) && !isHidden
        let yIdle = idle ? trayIconIdleOffset(sound: sound, date: timeline) : 0
        return VStack(spacing: 6) {
            mixerTokenIcon(sound)
                .offset(y: yIdle)
                .opacity(op)
            Text(trayCaptionLabel(sound))
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .opacity(op)
        }
        .frame(width: trayColumnWidth, height: trayColumnHeight, alignment: .top)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: TrayChipFrameKey.self, value: [sound: g.frame(in: .global)])
            }
        )
        .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let t = ProcessInfo.processInfo.systemUptime
                        trayDragPrevSample = trayDragLastSample
                        trayDragLastSample = (value.location, t)
                        if var existing = trayDrag, existing.sound == sound {
                            existing.globalLocation = value.location
                            trayDrag = existing
                        } else {
                            let origin = trayChipFrames[sound] ?? .zero
                            trayDrag = TrayDragState(
                                sound: sound,
                                globalLocation: value.location,
                                originGlobalFrame: origin
                            )
                        }
                    }
                    .onEnded { value in
                        let speed = trayFingerSpeedPointsPerSecond()
                        trayDragPrevSample = nil
                        trayDragLastSample = nil
                        if let u = snappedUnitOffsetForDrop(value.location, sound: sound) {
                            let f = effectiveCircleFrame()
                            let r = min(f.width, f.height) * 0.42
                            let center = CGPoint(x: f.midX, y: f.midY)
                            let targetGlobal = CGPoint(
                                x: center.x + CGFloat(u.x) * r,
                                y: center.y + CGFloat(u.y) * r
                            )
                            guard var drag = trayDrag, drag.sound == sound else {
                                trayDrag = nil
                                return
                            }
                            let spring = trayReturnSpring(speed: speed, baseResponse: 0.24, baseDamping: 0.9)
                            withAnimation(.spring(response: spring.response, dampingFraction: spring.damping)) {
                                drag.globalLocation = targetGlobal
                                trayDrag = drag
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                sleepVM.setSpatialSoundAt(sound, unitOffset: u)
                                trayDrag = nil
                            }
                        } else {
                            let origin = trayDrag?.originGlobalFrame ?? trayChipFrames[sound] ?? .zero
                            hiddenTraySounds.insert(sound)
                            animateTrayDragCancelled(
                                sound: sound,
                                startGlobal: value.location,
                                targetRect: origin,
                                speed: speed
                            )
                            trayDrag = nil
                        }
                    }
            )
    }

    /// Чип остаётся в иерархии (иначе SwiftUI срывает DragGesture), но визуально скрываем во время перетаскивания и полёта назад.
    private func trayChipListOpacity(isHidden: Bool, sound: SleepSound) -> Double {
        if isSoundInReturnFlight(sound) { return 0 }
        if isHidden { return 0 }
        if trayDrag?.sound == sound { return 0 }
        return 1
    }

    private func platformFingerSpeedPointsPerSecond() -> CGFloat {
        guard let prev = platformDragPrevSample, let last = platformDragLastSample else { return 0 }
        let dt = last.1 - prev.1
        guard dt > 0.000_1 else { return 0 }
        let d = hypot(last.0.x - prev.0.x, last.0.y - prev.0.y)
        return CGFloat(d / dt)
    }

    private func trayFingerSpeedPointsPerSecond() -> CGFloat {
        guard let prev = trayDragPrevSample, let last = trayDragLastSample else { return 0 }
        let dt = last.1 - prev.1
        guard dt > 0.000_1 else { return 0 }
        let d = hypot(last.0.x - prev.0.x, last.0.y - prev.0.y)
        return CGFloat(d / dt)
    }

    private func trayReturnSpring(speed: CGFloat, baseResponse: Double, baseDamping: Double) -> (response: Double, damping: Double) {
        let s = Double(speed)
        let response = baseResponse + min(0.14, s / 9000)
        let damping = min(0.95, baseDamping + min(0.12, s / 12000))
        return (response, damping)
    }

    private func fallbackReturnPointForTray(sound: SleepSound) -> CGPoint {
        if let f = trayChipFrames[sound], f.width > 2, f.height > 2 {
            return CGPoint(x: f.midX, y: f.midY)
        }
        let all = trayChipFrames.values.filter { $0.width > 2 && $0.height > 2 }
        if !all.isEmpty {
            let avgX = all.map(\.midX).reduce(0, +) / CGFloat(all.count)
            let avgY = all.map(\.midY).reduce(0, +) / CGFloat(all.count)
            return CGPoint(x: avgX, y: avgY)
        }
        let b = UIScreen.main.bounds
        return CGPoint(x: b.midX, y: b.maxY - 120)
    }

    private func animateTrayDragCancelled(sound: SleepSound, startGlobal: CGPoint, targetRect: CGRect, speed: CGFloat) {
        let target: CGPoint
        if targetRect.width > 2, targetRect.height > 2 {
            target = CGPoint(x: targetRect.midX, y: targetRect.midY)
        } else {
            target = fallbackReturnPointForTray(sound: sound)
        }
        let spring = trayReturnSpring(speed: speed, baseResponse: 0.32, baseDamping: 0.86)
        let tid = UUID()
        returningTokens.append(ReturningToken(id: tid, sound: sound, globalLocation: startGlobal))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            withAnimation(.spring(response: spring.response, dampingFraction: spring.damping)) {
                if let i = returningTokens.firstIndex(where: { $0.id == tid }) {
                    returningTokens[i].globalLocation = target
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                returningTokens.removeAll { $0.id == tid }
                hiddenTraySounds.remove(sound)
            }
        }
    }

    private func animateReturnToTray(sound: SleepSound, startGlobal: CGPoint, speed: CGFloat = 0) {
        hiddenTraySounds.insert(sound)
        let tid = UUID()
        returningTokens.append(ReturningToken(id: tid, sound: sound, globalLocation: startGlobal))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            let targetPoint: CGPoint
            if let target = trayChipFrames[sound], target.width > 2, target.height > 2 {
                targetPoint = CGPoint(x: target.midX, y: target.midY)
            } else {
                targetPoint = fallbackReturnPointForTray(sound: sound)
            }
            let spring = trayReturnSpring(speed: speed, baseResponse: 0.34, baseDamping: 0.88)
            withAnimation(.spring(response: spring.response, dampingFraction: spring.damping)) {
                if let idx = returningTokens.firstIndex(where: { $0.id == tid }) {
                    returningTokens[idx].globalLocation = targetPoint
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                hiddenTraySounds.remove(sound)
                returningTokens.removeAll { $0.id == tid }
            }
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

private struct SnakeDividerView: View {
    @State private var smoothLevel: Double = 0.72

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let base = Self.calmDescriptor
            Canvas { context, size in
                let dyn = max(0.10, min(1.0, smoothLevel))
                let basePath = buildWavePath(size: size, time: t, dyn: dyn, descriptor: base)
                drawWave(context: &context, path: basePath, size: size, dyn: dyn, descriptor: base)
            }
        }
        .onAppear { smoothLevel = 0.72 }
        .drawingGroup()
    }

    private static let calmDescriptor = SpatialMixerView.DividerMixDescriptor(
        baseAmplitude: 0.46,
        speed: 1.05,
        roughness: 0.30,
        glow: 0.34,
        motionA: 1.08,
        motionB: 1.24,
        interaction: 0.24,
        signature: 0.42
    )

    private func buildWavePath(
        size: CGSize,
        time: TimeInterval,
        dyn: Double,
        descriptor: SpatialMixerView.DividerMixDescriptor
    ) -> Path {
        let midY = size.height * 0.5
        let ampBase = max(0.36, size.height * (0.022 + 0.032 * dyn))
        let waveLen = max(96.0, size.width * (0.30 + 0.06 * (1 - dyn)))
        let travel = time * (26.0 + 14.0 * dyn)
        var path = Path()
        path.move(to: CGPoint(x: -8, y: midY))
        let step: CGFloat = 5
        var x: CGFloat = -8
        while x <= size.width + 8 {
            let amp = amplitudeFor(prof: descriptor, time: time, dyn: dyn, sizeHeight: size.height, ampBase: ampBase)
            let y = yForWave(
                x: x,
                midY: midY,
                time: time,
                dyn: dyn,
                waveLen: waveLen,
                travel: travel,
                amp: amp,
                prof: descriptor
            )
            path.addLine(to: CGPoint(x: x, y: y))
            x += step
        }
        return path
    }

    private func drawWave(
        context: inout GraphicsContext,
        path: Path,
        size: CGSize,
        dyn: Double,
        descriptor: SpatialMixerView.DividerMixDescriptor
    ) {
        let midY = size.height * 0.5
        context.stroke(
            path,
            with: .linearGradient(
                Gradient(colors: [
                    Color.purple.opacity(0.08),
                    Color.purple.opacity(0.84 + 0.10 * descriptor.interaction),
                    Color.white.opacity(0.50 + 0.32 * dyn),
                    Color.purple.opacity(0.88),
                    Color.purple.opacity(0.08)
                ]),
                startPoint: CGPoint(x: 0, y: midY),
                endPoint: CGPoint(x: size.width, y: midY)
            ),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        )

        context.addFilter(.blur(radius: 1.2))
        context.stroke(
            path,
            with: .color(Color.purple.opacity(0.20 + descriptor.glow * dyn)),
            style: StrokeStyle(lineWidth: 3.2 + (0.9 + descriptor.glow * 0.9) * dyn, lineCap: .round, lineJoin: .round)
        )
    }

    private func amplitudeFor(
        prof: SpatialMixerView.DividerMixDescriptor,
        time: TimeInterval,
        dyn: Double,
        sizeHeight: CGFloat,
        ampBase: CGFloat
    ) -> CGFloat {
        let envelopeA = 0.5 + 0.5 * sin(time * (0.28 + prof.motionA * 0.18))
        let envelopeB = 0.5 + 0.5 * sin(time * (0.18 + prof.motionB * 0.11) + 1.6)
        let env = 0.72 + 0.22 * envelopeA + 0.16 * envelopeB
        let softAmp = sizeHeight * (0.030 + (0.120 + 0.180 * prof.baseAmplitude) * dyn * env)
        return max(ampBase, softAmp)
    }

    private func yForWave(
        x: CGFloat,
        midY: CGFloat,
        time: TimeInterval,
        dyn: Double,
        waveLen: CGFloat,
        travel: Double,
        amp: CGFloat,
        prof: SpatialMixerView.DividerMixDescriptor
    ) -> CGFloat {
        let phase = (Double(x) + travel) / Double(waveLen) * (.pi * 2)
        let wobble = sin(phase * 0.48 + time * 0.56) * (0.05 + (0.08 + prof.roughness * 0.26) * dyn)
        let y2 = sin(phase * (1.22 + prof.signature * 0.44) + time * (0.30 + prof.signature * 0.22) + 1.4) * (0.024 + (0.054 + prof.interaction * 0.07) * dyn)
        let y3 = sin(phase * (1.95 + prof.signature * 0.66) - time * (0.18 + prof.signature * 0.20)) * (0.010 + 0.032 * prof.signature * dyn)
        return midY + CGFloat((sin(phase + wobble) + y2 + y3) * Double(amp))
    }

}

private struct StarfieldBackgroundView: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                for i in 0..<120 {
                    let baseX = CGFloat((i * 47 + i * i) % 1000) / 1000 * size.width
                    let baseY = CGFloat((i * 91 + i * 13) % 1000) / 1000 * size.height
                    let phase = Double(i) * 0.37
                    let twinkle = 0.55 + 0.45 * sin(t * (0.45 + Double(i % 5) * 0.07) + phase)
                    let driftX = CGFloat(sin(t * 0.03 + phase) * 1.8)
                    let driftY = CGFloat(cos(t * 0.025 + phase * 0.8) * 1.2)
                    let sizePx = 0.9 + CGFloat((i % 4)) * 0.5
                    let alpha = 0.05 + CGFloat(twinkle) * (0.06 + CGFloat(i % 7) * 0.03)
                    let p = Path(ellipseIn: CGRect(x: baseX + driftX, y: baseY + driftY, width: sizePx, height: sizePx))
                    context.fill(p, with: .color(Color.white.opacity(alpha)))
                }
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
