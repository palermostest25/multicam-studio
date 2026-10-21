import MulticamCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.inspectorTab) {
                Text("Edit").tag("edit")
                Text("Framing").tag("framing")
                Text("Export").tag("export")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            ScrollView {
                Group {
                    switch state.inspectorTab {
                    case "edit": EditSettings()
                    case "framing": FramingSettings()
                    default: ExportSettings()
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct SectionTitle: View {
    let text: String
    var detail: String?
    init(_ text: String, _ detail: String? = nil) { self.text = text; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.top, 6)
    }
}

// MARK: Edit

struct EditSettings: View {
    @EnvironmentObject var state: AppState
    @State private var advanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Camera switching", "Cuts land on the beat, faster in drops and slower in breakdowns. Angles are chosen from what each camera shows.")
            Picker("Main camera", selection: $state.project.mainCamera) {
                ForEach(state.project.cameras) { Text("\($0.id) · \($0.label)").tag($0.id) }
            }
            LabeledSlider(title: "Main camera screen time", value: $state.project.mainShare, range: 0.2...0.9,
                          format: { "\(Int(($0 * 100).rounded()))%" })
            LabeledSlider(title: "Pace", value: Binding(get: { 1 / state.project.cutScale }, set: { state.project.cutScale = 1 / $0 }),
                          range: 0.4...2.5, format: { $0 >= 1.05 ? String(format: "%.1f× faster", $0) : $0 <= 0.95 ? String(format: "%.1f× slower", 1 / $0) : "Normal" })
            HStack {
                Text("Variation")
                Spacer()
                TextField("Seed", value: $state.project.seed, format: .number.grouping(.never))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Button { state.shuffle() } label: { Image(systemName: "shuffle") }
                    .help("Try another edit")
            }
            Picker("Frame rate", selection: $state.project.fps) {
                ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }
            DisclosureGroup("Shot lengths (seconds)", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 8) {
                    RangeRow(title: "Main camera", values: $state.project.mainHold)
                    RangeRow(title: "Other cameras", values: $state.project.cutawayHold)
                    RangeRow(title: "Drops", values: $state.project.dropHold)
                    RangeRow(title: "Breakdowns", values: $state.project.breakdownHold)
                    Text("Pace multiplies these. Reels and Shorts use their own quicker lengths.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }

            Divider()
            SectionTitle("Music", state.currentAnalysis?.music.bpm.map { String(format: "%.1f BPM · beat confidence %.0f%%", $0, (state.currentAnalysis?.music.confidence ?? 0) * 100) })
            Toggle("Find breakdowns and drops automatically", isOn: $state.project.autoSections)
            if let part = state.currentPart, !part.drops.isEmpty || !part.breakdowns.isEmpty {
                Text("Your marked sections replace the automatic ones.").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(part.drops.enumerated()), id: \.offset) { i, d in
                    MarkerRow(kind: "Drop", range: d) { state.updatePart { $0.drops.remove(at: i) } }
                }
                ForEach(Array(part.breakdowns.enumerated()), id: \.offset) { i, d in
                    MarkerRow(kind: "Breakdown", range: d) { state.updatePart { $0.breakdowns.remove(at: i) } }
                }
            }

            Divider()
            SectionTitle("Forced cameras", "Drag across the timeline and pick a camera to force it there.")
            if let part = state.currentPart {
                if part.shotOverrides.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(Array(part.shotOverrides.enumerated()), id: \.offset) { i, o in
                    HStack {
                        Text(o.cameraID).bold()
                            .foregroundStyle(CameraColor.color(for: o.cameraID, in: state.project.cameras.map(\.id)))
                        Text("\(Timecode.short(o.start))–\(Timecode.short(o.end))").monospacedDigit()
                        Spacer()
                        Button { state.seek(toTimeline: o.start) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
                        Button { state.updatePart { $0.shotOverrides.remove(at: i) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }

            Divider()
            SyncSettings()
        }
    }
}

struct SyncSettings: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Sync", "Cameras are matched to the audio automatically. Set a manual start time only if a camera is wrong or has no sound.")
            ForEach(state.project.cameras.flatMap(\.clips)) { clip in
                SyncRow(clip: clip)
            }
            if let warnings = state.currentAnalysis?.warnings, !warnings.isEmpty {
                ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

struct SyncRow: View {
    @EnvironmentObject var state: AppState
    let clip: ClipSource
    @State private var text = ""

    var body: some View {
        let manual = state.currentPart?.overrides.first { $0.path == clip.path && $0.offset != nil }
        let synced = state.currentAnalysis?.clips.first { $0.url.path == clip.path }
        VStack(alignment: .leading, spacing: 4) {
            Text(clip.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            HStack {
                if let synced, manual == nil {
                    Text(String(format: "Auto: %+.3f s", synced.sync.offset)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Manual", isOn: Binding(get: { manual != nil }, set: { on in
                    state.setManualOffset(on ? (synced?.sync.offset ?? 0) : nil, for: clip.path)
                }))
                .toggleStyle(.checkbox)
                .font(.caption)
                if manual != nil {
                    TextField("seconds", text: $text)
                        .frame(width: 90)
                        .onAppear { text = String(format: "%.3f", manual?.offset ?? 0) }
                        .onSubmit { if let v = Double(text) { state.setManualOffset(v, for: clip.path) } }
                }
            }
        }
        .help("Offset = the audio time at which this recording's first frame happens. Negative means the camera started before the audio.")
    }
}

struct MarkerRow: View {
    let kind: String
    let range: [Double]
    let remove: () -> Void
    var body: some View {
        HStack {
            Text(kind)
            Text(range.count == 2 ? "\(Timecode.short(range[0]))–\(Timecode.short(range[1]))" : "").monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(format(value)).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: $value, in: range)
        }
    }
}

struct RangeRow: View {
    let title: String
    @Binding var values: [Double]
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("min", value: Binding(get: { values.first ?? 1 }, set: { values = [max(0.2, $0), max(max(0.2, $0), values.last ?? $0)] }), format: .number)
                .frame(width: 50)
            Text("–")
            TextField("max", value: Binding(get: { values.last ?? 1 }, set: { values = [min(values.first ?? $0, $0), max(0.2, $0)] }), format: .number)
                .frame(width: 50)
        }
        .multilineTextAlignment(.trailing)
    }
}

// MARK: Export

struct ExportSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Save to")
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text((state.project.outputDir as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(2).truncationMode(.middle)
                    .font(.callout)
                Spacer()
            }
            HStack {
                Button("Choose Folder…") { state.chooseOutputFolder() }
                Button("Show") { state.revealOutputs() }
            }
            TextField("File name (optional)", text: $state.project.outputName)
            Toggle("Replace existing files", isOn: $state.project.overwrite)
            if state.parts.count > 1 {
                Text("Each audio excerpt gets its own numbered folder inside this one.").font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Toggle(isOn: $state.project.fullEdit) { Text("Full edit").font(.headline) }
            if state.project.fullEdit {
                FormatPicker(aspect: $state.project.aspect, resolution: $state.project.resolution)
            }

            Divider()
            Toggle(isOn: Binding(get: { state.project.clips > 0 }, set: { state.project.clips = $0 ? 15 : 0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Short clips").font(.headline)
                    Text("Reels, Shorts and TikTok: cut on bar lines, quicker editing").font(.caption).foregroundStyle(.secondary)
                }
            }
            if state.project.clips > 0 {
                HStack(spacing: 6) {
                    ForEach([7.0, 15, 30, 60, 90], id: \.self) { length in
                        Button("\(Int(length)) s") { state.project.clips = length }
                            .buttonStyle(.bordered)
                            .tint(state.project.clips == length ? .accentColor : nil)
                            .controlSize(.small)
                    }
                }
                Stepper(value: $state.project.clips, in: 3...600, step: 1) {
                    Text("About \(Int(state.project.clips)) seconds each")
                }
                Picker("Choose", selection: $state.project.clipMode) {
                    ForEach(ClipMode.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $state.project.clipCount, in: 0...200) {
                    Text(state.project.clipCount == 0 ? "As many as fit" : "\(state.project.clipCount) clip\(state.project.clipCount == 1 ? "" : "s")")
                }
                FormatPicker(aspect: $state.project.clipAspect, resolution: $state.project.clipResolution)
                LabeledSlider(title: "Audio fade", value: $state.project.clipFade, range: 0...2,
                              format: { $0 < 0.05 ? "Off" : String(format: "%.1f s", $0) })
                Text(state.project.clipMode == .best
                     ? "Picks the most energetic moments, favouring a build-up into a drop. Clips only use stretches where a camera recorded."
                     : "Splits the whole set into back-to-back clips on bar lines.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            SectionTitle("Video")
            Picker("Codec", selection: $state.project.codec) {
                ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
            }
            if state.project.codec != .prores {
                LabeledSlider(title: "Quality", value: Binding(get: { Double(30 - state.project.crf) }, set: { state.project.crf = 30 - Int($0.rounded()) }),
                              range: 2...16, format: { v in v >= 14 ? "Highest" : v >= 11 ? "High" : v >= 8 ? "Good" : "Small files" })
            }
            Picker("Frame rate", selection: $state.project.fps) {
                ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
            }

            Divider()
            LookSettings()

            Divider()
            if let plan = state.plan {
                let count = (state.project.fullEdit ? 1 : 0) + plan.clips.count
                Text("\(count) video\(count == 1 ? "" : "s") per audio excerpt · hardware encoding")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                state.export()
            } label: {
                Label(state.phase == .rendering ? "Exporting…" : "Export", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.busy || !state.hasSources)
        }
    }
}

struct FormatPicker: View {
    @Binding var aspect: Aspect
    @Binding var resolution: Int
    var body: some View {
        Picker("Shape", selection: $aspect) {
            ForEach(Aspect.allCases) { Text($0.title).tag($0) }
        }
        Picker("Size", selection: $resolution) {
            ForEach([2160, 1440, 1080, 720], id: \.self) { r in
                let s = aspect.size(resolution: r)
                Text("\(r == 2160 ? "4K" : "\(r)p") · \(s.width)×\(s.height)").tag(r)
            }
        }
    }
}

struct LookSettings: View {
    @EnvironmentObject var state: AppState
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Colour", selection: $state.project.look.style) {
                    ForEach(Look.Style.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "Brightness", value: $state.project.look.brightness, range: -0.3...0.3, format: { String(format: "%+.2f", $0) })
                LabeledSlider(title: "Contrast", value: $state.project.look.contrast, range: 0.5...2, format: { String(format: "%.2f", $0) })
                LabeledSlider(title: "Saturation", value: $state.project.look.saturation, range: 0...2, format: { String(format: "%.2f", $0) })
                Toggle("Vignette", isOn: $state.project.look.vignette)
                LabeledSlider(title: "Fade in", value: $state.project.look.fadeIn, range: 0...5, format: { $0 < 0.05 ? "Off" : String(format: "%.1f s", $0) })
                LabeledSlider(title: "Fade out", value: $state.project.look.fadeOut, range: 0...5, format: { $0 < 0.05 ? "Off" : String(format: "%.1f s", $0) })
                Button("Reset look") { state.project.look = Look() }.buttonStyle(.link)
            }
            .padding(.top, 6)
        } label: {
            Text("Look").font(.headline)
            if !state.project.look.isNeutral || state.project.look.fadeIn > 0 || state.project.look.fadeOut > 0 {
                Text("on").font(.caption).foregroundStyle(.tint)
            }
        }
    }
}
