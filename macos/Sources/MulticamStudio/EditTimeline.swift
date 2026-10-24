import AVFoundation
import MulticamCore
import SwiftUI

/// Publishes the player position without redrawing the rest of the window.
final class PlayheadClock: ObservableObject {
    @Published var time: Double = 0
    private var token: Any?
    private weak var player: AVPlayer?

    func attach(_ player: AVPlayer) {
        guard self.player !== player else { return }
        if let token, let old = self.player { old.removeTimeObserver(token) }
        self.player = player
        token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            self?.time = t.seconds.isFinite ? t.seconds : 0
        }
    }
    deinit { if let token, let player { player.removeTimeObserver(token) } }
}

struct EditTimeline: View {
    @EnvironmentObject var state: AppState
    @StateObject private var clock = PlayheadClock()
    @State private var pixelsPerSecond: Double = 2
    @State private var selection: ClosedRange<Double>?
    @State private var dragStart: Double?
    @State private var snap = true

    private let rulerHeight: CGFloat = 18
    private let sectionHeight: CGFloat = 14
    private let waveHeight: CGFloat = 54
    private let laneHeight: CGFloat = 22

    var duration: Double { state.currentAnalysis?.duration ?? state.mediaInfo[state.currentPart?.path ?? ""]?.duration ?? 0 }
    var ids: [String] { state.project.cameras.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { geo in
                let fit = max(0.05, (geo.size.width - 20) / max(duration, 1))
                let scale = max(fit, pixelsPerSecond)
                ScrollViewReader { _ in
                    ScrollView(.horizontal) {
                        canvas(scale: scale)
                            .frame(width: max(geo.size.width, duration * scale + 20), height: totalHeight)
                    }
                }
                .onAppear { pixelsPerSecond = fit }
                .onChange(of: duration) { pixelsPerSecond = fit }
            }
            .frame(height: totalHeight + 14)
            if let selection { selectionBar(selection) }
        }
        .onAppear { clock.attach(state.player) }
    }

    var totalHeight: CGFloat { rulerHeight + sectionHeight + waveHeight + CGFloat(max(1, ids.count)) * laneHeight + 8 }

    var controls: some View {
        HStack(spacing: 10) {
            Text("Timeline").font(.headline)
            if let part = state.currentPart, state.parts.count > 1 {
                Text(URL(fileURLWithPath: part.path).lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { Legend(); Toggle("Snap to beats", isOn: $snap).toggleStyle(.checkbox).font(.caption) }
                Toggle("Snap to beats", isOn: $snap).toggleStyle(.checkbox).font(.caption)
                Color.clear.frame(width: 0, height: 0)
            }
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log2(pixelsPerSecond) }, set: { pixelsPerSecond = pow(2, $0) }), in: -4...6)
                .frame(width: 120)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    func timeAt(_ x: CGFloat, scale: Double) -> Double {
        let t = min(max(0, Double(x - 10) / scale), duration)
        guard snap, let music = state.currentAnalysis?.music, music.hasGrid else { return t }
        let grid = scale > 12 ? music.beats : music.downbeats
        guard let nearest = grid.min(by: { abs($0 - t) < abs($1 - t) }), abs(nearest - t) * scale < 14 else { return t }
        return nearest
    }

    func canvas(scale: Double) -> some View {
        let analysis = state.currentAnalysis
        let plan = state.activePlan
        let part = state.currentPart
        let playhead = clock.time + state.previewOffset
        let ids = self.ids
        return Canvas { context, size in
            let x0: CGFloat = 10
            func x(_ t: Double) -> CGFloat { x0 + CGFloat(t * scale) }
            // Ruler
            let step: Double = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 * scale >= 60 } ?? 900
            var t = 0.0
            while t <= duration {
                context.stroke(Path { $0.move(to: CGPoint(x: x(t), y: rulerHeight - 5)); $0.addLine(to: CGPoint(x: x(t), y: rulerHeight)) },
                               with: .color(.secondary.opacity(0.6)))
                context.draw(Text(Timecode.short(t)).font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: x(t) + 3, y: 6), anchor: .leading)
                t += step
            }
            var y = rulerHeight
            // Sections
            let sections = analysis.map { Engine.sections(project: state.project, part: part!, music: $0.music) } ?? []
            for s in sections {
                let color: Color = s.kind == "drop" ? .pink : s.kind == "build" ? .yellow : .blue
                context.fill(Path(CGRect(x: x(s.start), y: y + 2, width: max(1, x(s.end) - x(s.start)), height: sectionHeight - 4)),
                             with: .color(color.opacity(0.55)))
            }
            for d in analysis?.music.drops ?? [] {
                context.fill(Path(CGRect(x: x(d) - 1, y: y, width: 2, height: sectionHeight + waveHeight)), with: .color(.pink))
            }
            // Short-clip windows
            for clip in plan?.clips ?? [] {
                let r = CGRect(x: x(clip.window.start), y: y, width: x(clip.window.end) - x(clip.window.start), height: sectionHeight)
                context.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                context.draw(Text("\(clip.index)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white),
                             at: CGPoint(x: r.midX, y: r.midY))
            }
            y += sectionHeight
            // Waveform
            if let wave = analysis?.waveform, !wave.isEmpty {
                let mid = y + waveHeight / 2
                var path = Path()
                let n = wave.count
                let columns = Int(min(Double(n), duration * scale))
                for c in 0..<max(1, columns) {
                    let i = c * n / max(1, columns)
                    let px = x(Double(i) / Double(n) * duration)
                    let h = CGFloat(wave[i]) * (waveHeight / 2 - 2)
                    path.addRect(CGRect(x: px, y: mid - h, width: max(1, CGFloat(duration * scale) / CGFloat(columns) - 0.5), height: h * 2))
                }
                context.fill(path, with: .color(.accentColor.opacity(0.75)))
            } else {
                context.draw(Text("Sync & Analyse to see the waveform, beats and drops").font(.caption).foregroundStyle(.secondary),
                             at: CGPoint(x: size.width / 2, y: y + waveHeight / 2))
            }
            // Bars when zoomed in
            if let music = analysis?.music, music.hasGrid, scale > 6 {
                for b in music.downbeats where b * scale > 0 {
                    context.stroke(Path { $0.move(to: CGPoint(x: x(b), y: y)); $0.addLine(to: CGPoint(x: x(b), y: y + waveHeight)) },
                                   with: .color(.white.opacity(0.18)))
                }
            }
            y += waveHeight + 4
            // Camera lanes: coverage (faint) and planned shots (solid)
            let fps = Double(plan?.fps ?? state.project.fps)
            let cover = analysis?.coverage(fps: Int(fps)) ?? []
            for (lane, id) in ids.enumerated() {
                let color = CameraColor.color(for: id, in: ids)
                let ly = y + CGFloat(lane) * laneHeight
                context.draw(Text(id).font(.system(size: 10, weight: .bold)).foregroundStyle(color), at: CGPoint(x: 2, y: ly + laneHeight / 2), anchor: .leading)
                if let analysis {
                    for (i, clip) in analysis.clips.enumerated() where clip.cameraID == id && i < cover.count {
                        let r = CGRect(x: x(Double(cover[i].first) / fps), y: ly + 3, width: x(Double(cover[i].last) / fps) - x(Double(cover[i].first) / fps), height: laneHeight - 6)
                        context.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color.opacity(0.16)))
                    }
                    let shots = state.previewTarget == .full ? (plan?.shots ?? [])
                        : (plan?.clips.first { PreviewTarget.clip($0.index) == state.previewTarget }?.shots ?? plan?.shots ?? [])
                    for s in shots {
                        guard let c = s.camera, analysis.clips.indices.contains(c), analysis.clips[c].cameraID == id else { continue }
                        let r = CGRect(x: x(Double(s.start) / fps), y: ly + 3, width: max(1, x(Double(s.end) / fps) - x(Double(s.start) / fps) - 1), height: laneHeight - 6)
                        context.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(color.opacity(s.reason.hasPrefix("manual") ? 1 : 0.8)))
                        if s.reason.hasPrefix("manual") {
                            context.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white), lineWidth: 1.5)
                        }
                    }
                }
            }
            // Stretches kept out of social clips: a red band across the waveform and lanes.
            for range in state.currentPart?.clipExcludes ?? [] where range.count == 2 {
                let r = CGRect(x: x(range[0]), y: rulerHeight, width: max(2, x(range[1]) - x(range[0])), height: size.height - rulerHeight)
                context.fill(Path(r), with: .color(.red.opacity(0.13)))
                context.fill(Path(CGRect(x: r.minX, y: rulerHeight, width: r.width, height: 3)), with: .color(.red.opacity(0.75)))
            }
            // Selection
            if let selection {
                let r = CGRect(x: x(selection.lowerBound), y: rulerHeight, width: max(2, x(selection.upperBound) - x(selection.lowerBound)), height: size.height - rulerHeight)
                context.fill(Path(r), with: .color(.white.opacity(0.12)))
                context.stroke(Path(r), with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
            // Playhead
            if duration > 0 {
                context.fill(Path(CGRect(x: x(playhead) - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.red))
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let a = timeAt(value.startLocation.x, scale: scale), b = timeAt(value.location.x, scale: scale)
                    if abs(value.translation.width) < 3 { return }
                    selection = min(a, b)...max(a, b)
                }
                .onEnded { value in
                    if abs(value.translation.width) < 3 {
                        selection = nil
                        state.seek(toTimeline: min(max(0, Double(value.location.x - 10) / scale), duration))
                    }
                }
        )
    }

    func selectionBar(_ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text("\(Timecode.short(range.lowerBound))–\(Timecode.short(range.upperBound)) (\(String(format: "%.1f", range.upperBound - range.lowerBound)) s)")
                .monospacedDigit()
            Divider().frame(height: 14)
            Text("Force camera:")
            ForEach(ids, id: \.self) { id in
                Button(id) {
                    state.addForcedInterval(start: range.lowerBound, end: range.upperBound, camera: id)
                    selection = nil
                }
                .tint(CameraColor.color(for: id, in: ids))
                .glassButton(prominent: true)
                .controlSize(.small)
            }
            Divider().frame(height: 14)
            Group {
                Button("Mark drop") { state.addMarker(start: range.lowerBound, end: range.upperBound, kind: "drop"); selection = nil }
                Button("Mark breakdown") { state.addMarker(start: range.lowerBound, end: range.upperBound, kind: "breakdown"); selection = nil }
                Button("No social clips here") { state.excludeFromClips(start: range.lowerBound, end: range.upperBound); selection = nil }
                    .help("Social clips will never be taken from this stretch")
                Button("Play") { state.seek(toTimeline: range.lowerBound); state.player.play() }
            }
            .controlSize(.small)
            .modifier(SelectionButtons())
            Spacer()
            Button { selection = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .modifier(SelectionBarBackground())
    }
}

/// Classic: the 2.0 grey bar. Liquid Glass: a floating glass capsule.
private struct SelectionBarBackground: ViewModifier {
    @AppStorage(Appearance.key) private var glass = true
    func body(content: Content) -> some View {
        if glass {
            content.glassCapsule().glassGroup(spacing: 6).padding(.horizontal, 10).padding(.bottom, 6)
        } else {
            content.background(.quaternary.opacity(0.5))
        }
    }
}

private struct SelectionButtons: ViewModifier {
    @AppStorage(Appearance.key) private var glass = true
    func body(content: Content) -> some View {
        if glass { content.glassButton() } else { content }
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([("Breakdown", Color.blue), ("Build", .yellow), ("Drop", .pink)], id: \.0) { name, color in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.6)).frame(width: 10, height: 8)
                    Text(name)
                }
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2).stroke(.primary, lineWidth: 1).frame(width: 10, height: 8)
                Text("Clip")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}
