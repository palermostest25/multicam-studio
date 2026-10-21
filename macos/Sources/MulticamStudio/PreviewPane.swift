import AVKit
import MulticamCore
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct Transport: View {
    @EnvironmentObject var state: AppState
    @StateObject private var clock = PlayheadClock()
    @State private var playing = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if state.player.rate > 0 { state.player.pause() } else { state.player.play() }
                playing = state.player.rate > 0
            } label: { Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 14) }
            .help("Play or pause the preview")
            Button {
                let now = clock.time + state.previewOffset
                if let next = state.currentAnalysis?.music.drops.first(where: { $0 > now + 0.5 }) {
                    state.seek(toTimeline: max(0, next - 4)); state.player.play(); playing = true
                }
            } label: { Image(systemName: "forward.end.fill") }
            .help("Jump to just before the next drop")
            .disabled(state.currentAnalysis?.music.drops.isEmpty ?? true)
            Text(Timecode.short(clock.time + state.previewOffset))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .onAppear { clock.attach(state.player) }
        .onReceive(clock.$time) { _ in playing = state.player.rate > 0 }
    }
}

struct PreviewPane: View {
    @EnvironmentObject var state: AppState
    @AppStorage(Appearance.key) private var glass = true

    var body: some View {
        // The controls sit above the picture, and the picture keeps the output's exact shape,
        // centred on the window background, so there are no black bands around it.
        VStack(spacing: 0) {
            header
                .padding(.horizontal, glass ? 10 : 12)
                .padding(.vertical, 8)
                .glassGroup(spacing: 10)
            stage
                .aspectRatio(shape, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding([.horizontal, .bottom], 8)
        }
        .frame(minHeight: 260)
    }

    /// Width ÷ height of what the player shows: the full edit or the selected short clip.
    var shape: CGFloat {
        let aspect: Aspect = if case .clip = state.previewTarget { state.project.clipAspect } else { state.project.aspect }
        let (w, h) = aspect.ratio
        return CGFloat(w) / CGFloat(h)
    }

    var header: some View {
        HStack(spacing: 10) {
            if let plan = state.activePlan {
                Transport()
                    .padding(.horizontal, glass ? 12 : 0)
                    .padding(.vertical, glass ? 7 : 0)
                    .glassCapsule(interactive: true)
                Picker("Preview", selection: $state.previewTarget) {
                    Text("Full edit · \(state.project.aspect.rawValue)").tag(PreviewTarget.full)
                    ForEach(plan.clips) { clip in
                        Text("\(clip.label) · \(Timecode.short(clip.window.start))")
                            .tag(PreviewTarget.clip(clip.index))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, glass ? 6 : 0)
                .padding(.vertical, glass ? 3 : 0)
                .glassCapsule(interactive: true)
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    PlanSummary(plan: plan, detailed: true)
                    PlanSummary(plan: plan, detailed: false)
                    Color.clear.frame(width: 0, height: 0)
                }
                .padding(.horizontal, glass ? 12 : 0)
                .padding(.vertical, glass ? 7 : 0)
                .glassCapsule()
            } else {
                Text(state.currentAnalysis == nil ? "Preview" : "Planning…")
                    .font(.headline)
                    .padding(.horizontal, glass ? 14 : 0)
                    .padding(.vertical, glass ? 7 : 0)
                    .glassCapsule()
                Spacer()
            }
        }
    }

    var stage: some View {
        ZStack {
            Color.black
            if state.activePlan != nil {
                PlayerView(player: state.player)
            } else if state.phase == .analysing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(state.status).foregroundStyle(.secondary)
                }
                .padding(glass ? 22 : 0)
                .glassSurface(RoundedRectangle(cornerRadius: 20))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("Sync & Analyse to see the edit here, ready to play before you export.")
                        .foregroundStyle(.secondary)
                    Button("Sync & Analyse") { state.analyse() }
                        .glassButton(prominent: true)
                        .disabled(state.busy)
                }
                .padding(glass ? 26 : 0)
                .glassSurface(RoundedRectangle(cornerRadius: 24))
            }
        }
    }
}

struct PlanSummary: View {
    @EnvironmentObject var state: AppState
    let plan: EditPlan
    var detailed = true

    var body: some View {
        let ids = state.project.cameras.map(\.id)
        let analysis = state.currentAnalysis
        let shots = plan.shots.filter { $0.camera != nil }
        let covered = max(1, shots.map { $0.end - $0.start }.reduce(0, +))
        HStack(spacing: 12) {
            if detailed, let bpm = analysis?.music.bpm {
                Label("\(Int(bpm.rounded())) BPM", systemImage: "metronome")
            }
            if detailed { Label("\(plan.shots.count) shots", systemImage: "scissors") }
            ForEach(ids, id: \.self) { id in
                let frames = shots.filter { shot in
                    guard let clips = analysis?.clips, let c = shot.camera, clips.indices.contains(c) else { return false }
                    return clips[c].cameraID == id
                }.map { $0.end - $0.start }.reduce(0, +)
                HStack(spacing: 4) {
                    Circle().fill(CameraColor.color(for: id, in: ids)).frame(width: 8, height: 8)
                    Text("\(id) \(Int((Double(frames) / Double(covered) * 100).rounded()))%")
                }
            }
            let black = plan.shots.filter { $0.camera == nil }.map { $0.end - $0.start }.reduce(0, +)
            if black > 0 {
                Label(Timecode.short(Double(black) / Double(plan.fps)) + " no footage", systemImage: "rectangle.slash")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }
}
