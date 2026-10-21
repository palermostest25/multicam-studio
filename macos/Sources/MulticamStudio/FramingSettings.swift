import AVFoundation
import MulticamCore
import SwiftUI

struct FramingSettings: View {
    @EnvironmentObject var state: AppState
    @State private var target: Aspect?

    var clips: [ClipSource] { state.project.cameras.flatMap(\.clips) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Framing", "How each recording fills the frame. Crop fills it; Fit shows the whole picture over a blurred copy instead of black bars.")
            if clips.isEmpty {
                Text("Add a camera first.").foregroundStyle(.secondary)
            } else {
                Picker("Recording", selection: Binding(get: { state.selectedClipPath ?? clips[0].path }, set: { state.selectedClipPath = $0 })) {
                    ForEach(state.project.cameras) { camera in
                        ForEach(camera.clips) { clip in
                            Text("\(camera.id) · \(clip.url.lastPathComponent)").tag(clip.path)
                        }
                    }
                }
                let path = state.selectedClipPath ?? clips[0].path
                let shape = target ?? state.project.aspect
                Picker("Show for", selection: Binding(get: { shape }, set: { target = $0 })) {
                    Text("Full edit (\(state.project.aspect.rawValue))").tag(state.project.aspect)
                    if state.project.clips > 0 && state.project.clipAspect != state.project.aspect {
                        Text("Clips (\(state.project.clipAspect.rawValue))").tag(state.project.clipAspect)
                    }
                    ForEach(Aspect.allCases.filter { $0 != state.project.aspect && $0 != state.project.clipAspect }) {
                        Text($0.rawValue).tag($0)
                    }
                }
                if let framing = state.framing(for: path) {
                    FramingEditor(path: path, framing: framing, aspect: shape)
                        .id(path)
                }
            }
        }
    }
}

struct FramingEditor: View {
    @EnvironmentObject var state: AppState
    let path: String
    let framing: Framing
    let aspect: Aspect
    @State private var image: CGImage?
    @State private var time: Double = 0.3

    var info: MediaInfo? { state.mediaInfo[path] }
    var focus: [Double]? { state.currentAnalysis?.clips.first { $0.url.path == path }?.focus }

    func update(_ change: (inout Framing) -> Void) {
        var f = framing
        change(&f)
        state.setFraming(f, for: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: Binding(get: { framing.mode }, set: { mode in update { $0.mode = mode } })) {
                Text("Crop").tag(Framing.Mode.crop)
                Text("Fit").tag(Framing.Mode.fit)
                Text("Bars").tag(Framing.Mode.pad)
            }
            .pickerStyle(.segmented)
            preview
            Slider(value: $time, in: 0.02...0.98) { Text("Frame") }
                .onChange(of: time) { loadFrame() }
            if framing.mode == .crop {
                Toggle("Follow the action automatically", isOn: Binding(get: { framing.auto }, set: { on in update { $0.auto = on } }))
                if framing.auto && focus == nil {
                    Text("The automatic position is measured during Sync & Analyse; until then the crop is centred on your position.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledSlider(title: "Zoom", value: Binding(get: { framing.zoom }, set: { z in update { $0.zoom = z } }),
                              range: 1...4, format: { String(format: "%.2f×", $0) })
                Text("Drag the picture to move the crop.").font(.caption).foregroundStyle(.secondary)
            } else if framing.mode == .fit {
                Text("The whole picture is shown. Spare space is filled with a soft, blurred copy of the same shot.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("The whole picture is shown with black bars.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { loadFrame() }
    }

    var preview: some View {
        GeometryReader { geo in
            let size = info?.orientedSize ?? CGSize(width: 16, height: 9)
            let scale = min(geo.size.width / size.width, geo.size.height / size.height)
            let shown = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: (geo.size.height - shown.height) / 2)
            ZStack(alignment: .topLeading) {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().frame(width: shown.width, height: shown.height).offset(x: origin.x, y: origin.y)
                }
                if framing.mode == .crop, let info {
                    let style = LayerStyle(framing: framing, focus: focus, info: info)
                    let output = aspect.size(resolution: 1080)
                    let rect = style.cropRect(output: CGSize(width: output.width, height: output.height))
                    let r = CGRect(x: origin.x + rect.minX * scale, y: origin.y + rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
                    Path { p in
                        p.addRect(CGRect(origin: origin, size: shown))
                        p.addRect(r)
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    Rectangle().stroke(Color.yellow, lineWidth: 2).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard framing.mode == .crop, shown.width > 0 else { return }
                let x = min(1, max(0, (value.location.x - origin.x) / shown.width))
                let y = min(1, max(0, (value.location.y - origin.y) / shown.height))
                update { $0.center = [x, y]; $0.auto = false }
            })
        }
        .aspectRatio(max(0.5, min(2.2, info?.aspect ?? 16.0 / 9)), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    func loadFrame() {
        guard let info else { return }
        let url = URL(fileURLWithPath: path)
        let at = info.duration * time
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 900)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            if let result = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)) {
                image = result.image
            }
        }
    }
}
