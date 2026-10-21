import MulticamCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        List(selection: Binding(get: { state.selectedClipPath }, set: { state.selectedClipPath = $0; if $0 != nil { state.inspectorTab = "framing" } })) {
            Section {
                ForEach(Array(state.parts.enumerated()), id: \.element.path) { index, part in
                    AudioRow(part: part, index: index)
                }
                Button { state.addAudio(state.pickFiles(audio: true)) } label: {
                    Label(state.parts.isEmpty ? "Add audio…" : "Add another excerpt…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            } header: {
                Text("Audio")
            } footer: {
                if state.parts.count > 1 {
                    Text("Each excerpt exports as its own video. Click one to edit its timing.").font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach($state.project.cameras) { $camera in
                Section {
                    ForEach(camera.clips) { clip in
                        ClipRow(clip: clip, cameraID: camera.id).tag(clip.path)
                    }
                    Button {
                        state.addClips(state.pickFiles(audio: false), to: camera.id)
                    } label: {
                        Label(camera.clips.isEmpty ? "Add recording…" : "Add another part…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                } header: {
                    CameraHeader(camera: $camera)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    state.addClips(urls, to: camera.id); return true
                }
            }

            Section {
                Button {
                    let urls = state.pickFiles(audio: false)
                    if !urls.isEmpty { state.addCamera(with: urls) }
                } label: { Label("Add camera…", systemImage: "video.badge.plus") }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }
        }
        .listStyle(.sidebar)
    }
}

struct AudioRow: View {
    @EnvironmentObject var state: AppState
    let part: AudioPart
    let index: Int

    var body: some View {
        let url = URL(fileURLWithPath: part.path)
        let analysis = state.analyses[part.path]
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(state.selectedPart == index ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if let info = state.mediaInfo[part.path] { Text(Timecode.short(info.duration)) }
                    if let bpm = analysis?.music.bpm { Text("· \(Int(bpm.rounded())) BPM") }
                    if let analysis, !analysis.music.drops.isEmpty { Text("· \(analysis.music.drops.count) drops") }
                    if !FileManager.default.fileExists(atPath: part.path) { Text("· missing").foregroundStyle(.red) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { state.selectedPart = index; state.schedulePlan(immediately: true) }
        .padding(.vertical, 2)
        .listRowBackground(state.selectedPart == index && state.parts.count > 1 ? Color.accentColor.opacity(0.12) : nil)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove", role: .destructive) { state.removeAudio(part.path) }
        }
    }
}

struct CameraHeader: View {
    @EnvironmentObject var state: AppState
    @Binding var camera: CameraDefinition

    var body: some View {
        HStack(spacing: 6) {
            Text(camera.id)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(CameraColor.color(for: camera.id, in: state.project.cameras.map(\.id)).opacity(0.85), in: Capsule())
                .foregroundStyle(.white)
            TextField("Name", text: $camera.label)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .textCase(nil)
            Spacer()
            Button {
                state.project.mainCamera = camera.id
            } label: {
                Image(systemName: state.project.mainCamera == camera.id ? "star.fill" : "star")
                    .foregroundStyle(state.project.mainCamera == camera.id ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Main camera: gets the long holds and breakdowns")
            Menu {
                Button("Remove Camera \(camera.id)", role: .destructive) { state.removeCamera(camera.id) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

struct ClipRow: View {
    @EnvironmentObject var state: AppState
    let clip: ClipSource
    let cameraID: String

    var body: some View {
        let info = state.mediaInfo[clip.path]
        let synced = state.currentAnalysis?.clips.first { $0.url.path == clip.path }
        let excluded = state.currentAnalysis?.excluded.first { $0.path == clip.path }
        let idle = excluded?.noFootage ?? false
        let failed = state.currentAnalysis != nil && synced == nil && !idle
        HStack(spacing: 8) {
            Image(systemName: synced != nil ? "checkmark.circle.fill" : idle ? "moon.zzz" : failed ? "exclamationmark.triangle.fill" : "film")
                .foregroundStyle(synced != nil ? .green : failed ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Group {
                    if let synced {
                        Text((synced.sync.offset >= 0 ? "starts \(Timecode.short(synced.sync.offset)) into the audio"
                              : "started \(Timecode.short(-synced.sync.offset)) before the audio")
                             + (synced.sync.method == "manual" ? " · manual" : ""))
                    } else if idle {
                        Text("not recording during this audio")
                    } else if failed {
                        if let suggested = excluded?.suggestedOffset {
                            Text("couldn't sync · clock says ≈\(String(format: "%+.0f", suggested)) s")
                        } else {
                            Text("couldn't sync to this audio")
                        }
                    } else if let info {
                        Text("\(Timecode.short(info.duration)) · \(Int(info.orientedSize.width))×\(Int(info.orientedSize.height))\(info.isHDR ? " HDR" : "")")
                    } else if !FileManager.default.fileExists(atPath: clip.path) {
                        Text("missing").foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(clip.framing.mode == .crop ? (clip.framing.auto ? "Auto" : "Crop") : clip.framing.mode == .fit ? "Fit" : "Pad")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Frame This Clip") { state.selectedClipPath = clip.path; state.inspectorTab = "framing" }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            Button("Remove", role: .destructive) { state.removeClip(clip.path) }
        }
    }
}

enum CameraColor {
    static let palette: [Color] = [
        Color(red: 0.95, green: 0.62, blue: 0.25), Color(red: 0.35, green: 0.72, blue: 0.85),
        Color(red: 0.62, green: 0.48, blue: 0.95), Color(red: 0.42, green: 0.80, blue: 0.45),
        Color(red: 0.92, green: 0.40, blue: 0.55), Color(red: 0.85, green: 0.80, blue: 0.30),
    ]
    static func color(for id: String, in ids: [String]) -> Color {
        palette[(ids.firstIndex(of: id) ?? 0) % palette.count]
    }
}
