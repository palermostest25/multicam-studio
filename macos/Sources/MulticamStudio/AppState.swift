import AppKit
import AVFoundation
import Combine
import MulticamCore
import SwiftUI
import UniformTypeIdentifiers

enum Phase: Equatable {
    case idle
    case analysing
    case rendering
}

enum PreviewTarget: Hashable {
    case full
    case clip(Int)
}

struct LogLine: Identifiable {
    let id = UUID()
    let text: String
    let isWarning: Bool
}

@MainActor
final class AppState: ObservableObject {
    @Published var project = Project() { didSet { projectChanged(from: oldValue) } }
    @Published var projectURL: URL?
    @Published var isDirty = false
    @Published var mediaInfo: [String: MediaInfo] = [:]
    @Published var analyses: [String: PartAnalysis] = [:]
    @Published var selectedPart = 0
    @Published var selectedClipPath: String?
    @Published var plan: EditPlan?
    @Published var planError: String?
    @Published var phase: Phase = .idle
    @Published var status = "Add your DJ set audio and camera recordings to begin."
    @Published var progress: Double?
    @Published var log: [LogLine] = []
    @Published var previewTarget: PreviewTarget = .full { didSet { if previewTarget != oldValue { rebuildPreview() } } }
    @Published var lastOutputs: [URL] = []
    @Published var errorMessage: String?
    @Published var inspectorTab = "export"

    let player = AVPlayer()
    private var work: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var planTask: Task<Void, Never>?
    private lazy var engine = Engine(log: { [weak self] line in
        Task { @MainActor in self?.append(line) }
    }, status: { [weak self] text, value in
        Task { @MainActor in self?.status = text; self?.progress = value }
    })

    nonisolated static let draftURL: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Multicam Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("Draft.multicam.json")
    }()

    init() {
        player.isMuted = false
        if let draft = try? Project.load(Self.draftURL) {
            project = draft
            isDirty = false
        }
        if project.outputDir.isEmpty {
            project.outputDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Multicam Studio Exports").path
        }
        refreshMediaInfo()
        // Pick up where you left off: cached sync/music/picture results make this about a second.
        let files = project.parts.map(\.path) + project.cameras.flatMap { $0.clips.map(\.path) }
        if hasSources, files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
            Task { @MainActor in self.analyse() }
        }
    }

    // MARK: derived

    var parts: [AudioPart] { project.parts }
    var currentPart: AudioPart? { parts.indices.contains(selectedPart) ? parts[selectedPart] : nil }
    var currentAnalysis: PartAnalysis? { currentPart.flatMap { analyses[$0.path] } }
    var busy: Bool { phase != .idle }
    /// The plan, but only while it belongs to the excerpt and recordings on screen. Its shot camera
    /// indices point into that analysis; pairing it with another excerpt would index past the end.
    var activePlan: EditPlan? { plan.flatMap { $0.matches(currentAnalysis) ? $0 : nil } }
    var hasSources: Bool { !parts.isEmpty && project.cameras.contains { !$0.clips.isEmpty } }
    var allAnalysed: Bool { !parts.isEmpty && parts.allSatisfy { analyses[$0.path] != nil } }

    func append(_ line: String) {
        log.append(LogLine(text: line, isWarning: line.hasPrefix("WARNING")))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    // MARK: editing

    private func projectChanged(from old: Project) {
        isDirty = true
        saveDraft()
        // Sources or sync settings changed: earlier analysis no longer applies.
        func cameraKey(_ p: Project) -> String {
            p.cameras.map { c in c.id + ":" + c.clips.map(\.path).joined(separator: ",") }.joined(separator: "|") + "#\(p.drift)#\(p.vision)"
        }
        func partKeys(_ p: Project) -> [String: String] {
            Dictionary(p.parts.map { part in
                (part.path, part.overrides.map { "\($0.path)=\($0.offset ?? .nan)/\($0.driftPPM ?? 0)" }.sorted().joined(separator: ";"))
            }, uniquingKeysWith: { a, _ in a })
        }
        if cameraKey(old) != cameraKey(project) {
            analyses.removeAll()
            refreshMediaInfo()
        } else {
            let before = partKeys(old), after = partKeys(project)
            if before != after {
                analyses = analyses.filter { key, _ in after[key] != nil && after[key] == before[key] }
                refreshMediaInfo()
            }
        }
        // Framing and look don't change the cuts: just redraw the preview.
        func withoutPicture(_ p: Project) -> Project {
            var q = p
            for i in q.cameras.indices { for j in q.cameras[i].clips.indices { q.cameras[i].clips[j].framing = Framing() } }
            q.look = Look()
            return q
        }
        if withoutPicture(old) == withoutPicture(project), plan != nil {
            schedulePreview()
        } else {
            schedulePlan()
        }
    }

    private var previewDebounce: Task<Void, Never>?
    func schedulePreview() {
        previewDebounce?.cancel()
        previewDebounce = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if !Task.isCancelled { rebuildPreview() }
        }
    }

    private func saveDraft() {
        let snapshot = project
        Task.detached(priority: .background) { try? snapshot.save(Self.draftURL) }
    }

    func refreshMediaInfo() {
        let paths = project.parts.map(\.path) + project.cameras.flatMap { $0.clips.map(\.path) }
        for path in paths where mediaInfo[path] == nil {
            Task {
                if let info = try? await Media.info(URL(fileURLWithPath: path)) { mediaInfo[path] = info }
            }
        }
    }

    func addAudio(_ urls: [URL]) {
        var parts = project.audioParts
        if parts.isEmpty && !project.audio.isEmpty { parts = project.parts }
        for url in urls where Media.audioExtensions.contains(url.pathExtension.lowercased()) || Media.videoExtensions.contains(url.pathExtension.lowercased()) {
            if !parts.contains(where: { $0.path == url.path }) { parts.append(AudioPart(path: url.path)) }
        }
        setParts(parts)
    }

    func setParts(_ parts: [AudioPart]) {
        if parts.count <= 1 {
            var p = project
            p.audioParts = []
            p.audio = parts.first?.path ?? ""
            if let part = parts.first {
                p.overrides = part.overrides; p.shotOverrides = part.shotOverrides
                p.drops = part.drops; p.breakdowns = part.breakdowns; p.activities = part.activities
            }
            project = p
        } else {
            project.audioParts = parts
            project.audio = parts[0].path
        }
        selectedPart = min(selectedPart, max(0, parts.count - 1))
    }

    func removeAudio(_ path: String) { setParts(parts.filter { $0.path != path }) }

    func updatePart(_ change: (inout AudioPart) -> Void) {
        guard var part = currentPart else { return }
        change(&part)
        var all = parts
        all[selectedPart] = part
        setParts(all)
    }

    func nextCameraID() -> String {
        let used = Set(project.cameras.map(\.id))
        for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" where !used.contains(String(letter)) { return String(letter) }
        return "Cam\(project.cameras.count + 1)"
    }

    func addCamera(with urls: [URL] = []) {
        let id = nextCameraID()
        let clips = urls.filter { Media.videoExtensions.contains($0.pathExtension.lowercased()) }.map { ClipSource(path: $0.path) }
        project.cameras.append(CameraDefinition(id: id, label: "Camera \(id)", clips: clips))
        if project.cameras.count == 1 { project.mainCamera = id }
    }

    func addClips(_ urls: [URL], to cameraID: String) {
        guard let i = project.cameras.firstIndex(where: { $0.id == cameraID }) else { return }
        let existing = Set(project.cameras.flatMap { $0.clips.map(\.path) })
        for url in urls where Media.videoExtensions.contains(url.pathExtension.lowercased()) && !existing.contains(url.path) {
            project.cameras[i].clips.append(ClipSource(path: url.path))
        }
    }

    /// Dropped files: audio becomes excerpts, each video becomes its own camera.
    func handleDrop(_ urls: [URL]) {
        let audio = urls.filter { Media.audioExtensions.contains($0.pathExtension.lowercased()) }
        let video = urls.filter { Media.videoExtensions.contains($0.pathExtension.lowercased()) }
        if !audio.isEmpty { addAudio(audio) }
        for url in video { addCamera(with: [url]) }
    }

    func removeCamera(_ id: String) {
        project.cameras.removeAll { $0.id == id }
        if project.mainCamera == id { project.mainCamera = project.cameras.first?.id ?? "A" }
    }

    func removeClip(_ path: String) {
        for i in project.cameras.indices { project.cameras[i].clips.removeAll { $0.path == path } }
        if selectedClipPath == path { selectedClipPath = nil }
    }

    func framing(for path: String) -> Framing? {
        project.cameras.flatMap(\.clips).first { $0.path == path }?.framing
    }

    func setFraming(_ framing: Framing, for path: String) {
        for i in project.cameras.indices {
            if let j = project.cameras[i].clips.firstIndex(where: { $0.path == path }) { project.cameras[i].clips[j].framing = framing }
        }
    }

    func setManualOffset(_ offset: Double?, for path: String) {
        updatePart { part in
            part.overrides.removeAll { $0.path == path }
            if let offset { part.overrides.append(SyncOverride(path: path, offset: offset, driftPPM: nil)) }
        }
    }

    func addForcedInterval(start: Double, end: Double, camera: String) {
        updatePart { part in
            part.shotOverrides.removeAll { $0.start < end && start < $0.end }
            part.shotOverrides.append(ShotOverride(start: start, end: end, cameraID: camera))
            part.shotOverrides.sort { $0.start < $1.start }
        }
    }

    func addMarker(start: Double, end: Double, kind: String) {
        updatePart { part in
            if kind == "drop" { part.drops.append([start, end]) } else { part.breakdowns.append([start, end]) }
        }
    }

    func shuffle() { project.seed = Int.random(in: 1...999_999) }

    /// Re-cut an already finished video: it is both the only camera and the soundtrack.
    func newFromFinishedVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.message = "Choose a finished video to cut into short clips"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newProject()
        var p = project
        p.cameras = [CameraDefinition(id: "A", label: url.deletingPathExtension().lastPathComponent,
                                      clips: [ClipSource(path: url.path, framing: Framing(mode: .crop, auto: true))])]
        p.mainCamera = "A"
        p.audio = url.path
        p.overrides = [SyncOverride(path: url.path, offset: 0, driftPPM: nil)]
        p.fullEdit = false
        p.clips = 15
        p.clipCount = 10
        p.outputName = url.deletingPathExtension().lastPathComponent
        project = p
        inspectorTab = "export"
        analyse()
    }

    // MARK: files

    func newProject() {
        cancel()
        var fresh = Project()
        fresh.outputDir = project.outputDir
        project = fresh
        projectURL = nil
        analyses.removeAll()
        plan = nil
        log.removeAll()
        player.replaceCurrentItem(with: nil)
        isDirty = false
        status = "Add your DJ set audio and camera recordings to begin."
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Open a Multicam Studio project (from this app or the browser version)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let loaded = try Project.load(url)
            newProject()
            project = loaded
            projectURL = url
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            append("Opened \(url.lastPathComponent)")
            let missing = (loaded.parts.map(\.path) + loaded.cameras.flatMap { $0.clips.map(\.path) })
                .filter { !FileManager.default.fileExists(atPath: $0) }
            if !missing.isEmpty {
                errorMessage = "\(missing.count) recording(s) could not be found. Reconnect the drive they are on.\n\n" + missing.prefix(5).joined(separator: "\n")
            } else if hasSources {
                analyse()  // cached results make this nearly instant for a project seen before
            }
        } catch {
            errorMessage = "Could not open the project: \(error.localizedDescription)"
        }
    }

    func save(as: Bool = false) {
        var url = projectURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = (project.outputName.isEmpty ? "Multicam project" : project.outputName) + ".json"
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let url else { return }
        do {
            try project.save(url)
            projectURL = url
            isDirty = false
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where finished videos are saved"
        panel.directoryURL = URL(fileURLWithPath: (project.outputDir as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url { project.outputDir = url.path }
    }

    func pickFiles(audio: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = audio ? [.audio, .wav, .aiff, .mp3, .mpeg4Audio, .movie] : [.movie, .quickTimeMovie, .mpeg4Movie]
        panel.message = audio ? "Choose the DJ set audio (one file, or several excerpts)" : "Choose camera recordings"
        return panel.runModal() == .OK ? panel.urls : []
    }

    // MARK: analysis and planning

    func analyse() {
        guard hasSources, !busy else { return }
        let project = self.project
        let parts = self.parts
        phase = .analysing
        progress = nil
        work = Task {
            let started = Date()
            do {
                for (i, part) in parts.enumerated() where analyses[part.path] == nil {
                    append("Analysing \(URL(fileURLWithPath: part.path).lastPathComponent) (\(i + 1)/\(parts.count))")
                    let result = try await engine.analyse(project: project, part: part, vision: project.vision != "off")
                    analyses[part.path] = result
                    for warning in result.warnings { append("WARNING: " + warning) }
                }
                engine.releaseMemory()
                status = String(format: "Synced and analysed in %.0f s. Adjust the edit, preview it, then export.", Date().timeIntervalSince(started))
                schedulePlan(immediately: true)
            } catch is CancellationError {
                status = "Analysis cancelled."
            } catch {
                errorMessage = error.localizedDescription
                status = "Analysis needs attention."
            }
            phase = .idle
            progress = nil
        }
    }

    func schedulePlan(immediately: Bool = false) {
        planTask?.cancel()
        guard let analysis = currentAnalysis else { plan = nil; player.replaceCurrentItem(with: nil); return }
        if plan.map({ !$0.matches(analysis) }) ?? false {
            plan = nil  // never show another excerpt's plan while this one is computed
            player.replaceCurrentItem(with: nil)
        }
        let project = self.project
        planTask = Task {
            if !immediately { try? await Task.sleep(nanoseconds: 250_000_000) }
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<EditPlan, Error> in
                Result { try Engine.plan(project: project, analysis: analysis) }
            }.value
            if Task.isCancelled { return }
            switch result {
            case .success(let plan):
                guard plan.matches(currentAnalysis) else { return }  // the excerpt changed meanwhile
                self.plan = plan
                planError = nil
                if case .clip(let i) = previewTarget, !plan.clips.contains(where: { $0.index == i }) { previewTarget = .full }
                rebuildPreview()
            case .failure(let error):
                planError = error.localizedDescription
            }
        }
    }

    func rebuildPreview() {
        previewTask?.cancel()
        guard let plan = activePlan, let analysis = currentAnalysis else { player.replaceCurrentItem(with: nil); return }
        let project = self.project
        let target = previewTarget
        let time = player.currentTime()
        previewTask = Task {
            let shots: [Shot], window: Range<Int>, aspect: Aspect
            var fadeOut = 0.0
            var sources = Engine.currentSources(analysis, project: project)
            switch target {
            case .full:
                shots = plan.shots; window = 0..<plan.total; aspect = project.aspect
            case .clip(let index):
                guard let clip = plan.clips.first(where: { $0.index == index }) else { return }
                shots = clip.shots
                window = Int((clip.window.start * Double(plan.fps)).rounded())..<Int((clip.window.end * Double(plan.fps)).rounded())
                aspect = project.clipAspect
                fadeOut = Engine.clipFadeOut(clip.window)
                sources = Engine.clipSources(sources, aspect: aspect, mode: project.clipFraming)
            }
            // Preview at screen size: the same compositor as the export, just fewer pixels.
            let size = aspect.size(resolution: aspect == .landscape ? 540 : 720)
            let spec = OutputSpec(width: size.width, height: size.height, fps: plan.fps, codec: .h264, look: project.look)
            do {
                let edit = try await Renderer.prepare(shots: shots, clips: sources, bounce: URL(fileURLWithPath: analysis.part.path),
                                                      window: window, spec: spec, audioFade: target == .full ? 0 : project.clipFade,
                                                      declick: target == .full ? 0 : 0.015, audioFadeOut: fadeOut)
                if Task.isCancelled { return }
                let wasPlaying = player.rate > 0
                let item = edit.playerItem()
                player.replaceCurrentItem(with: item)
                Task { [weak self] in
                    for _ in 0..<50 where item.status == .unknown { try? await Task.sleep(nanoseconds: 100_000_000) }
                    if item.status == .failed { self?.planError = "Preview failed: \(item.error?.localizedDescription ?? "unknown error")" }
                    self?.append("Preview \(item.status == .readyToPlay ? "ready" : "status \(item.status.rawValue)") (\(spec.width)×\(spec.height))")
                }
                // Seeking draws the first frame straight away instead of a black box.
                let start = target == .full ? time : .zero
                await player.seek(to: CMTimeMaximum(start, CMTime(value: 1, timescale: 600)), toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { player.play() }
            } catch {
                if !Task.isCancelled { planError = error.localizedDescription }
            }
        }
    }

    /// Timeline seconds (bounce time) of the preview playhead.
    var previewOffset: Double {
        if case .clip(let i) = previewTarget, let clip = activePlan?.clips.first(where: { $0.index == i }) { return clip.window.start }
        return 0
    }

    func seek(toTimeline t: Double) {
        if case .clip(let i) = previewTarget, let clip = activePlan?.clips.first(where: { $0.index == i }),
           !(clip.window.start...clip.window.end).contains(t) {
            previewTarget = .full
        }
        let local = max(0, t - previewOffset)
        player.seek(to: CMTime(seconds: local, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: export

    func export() {
        guard !busy else { return }
        guard hasSources else { errorMessage = "Add audio and at least one camera first."; return }
        guard project.fullEdit || project.clips > 0 else { errorMessage = "Choose a full edit, short clips, or both."; return }
        let project = self.project
        let parts = self.parts
        phase = .rendering
        progress = 0
        lastOutputs = []
        player.pause()
        work = Task {
            let started = Date()
            do {
                var written = [URL]()
                for (i, part) in parts.enumerated() {
                    var analysis = analyses[part.path]
                    if analysis == nil {
                        append("Analysing \(URL(fileURLWithPath: part.path).lastPathComponent)")
                        analysis = try await engine.analyse(project: project, part: part, vision: project.vision != "off")
                        analyses[part.path] = analysis
                    }
                    let plan = try Engine.plan(project: project, analysis: analysis!)
                    let folder = Engine.outputFolder(project: project, partIndex: i + 1, partCount: parts.count, part: part)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try Engine.cutList(project: project, analysis: analysis!, plan: plan)
                        .write(to: folder.appendingPathComponent("\(Engine.baseName(project))_cut_list.txt"), atomically: true, encoding: .utf8)
                    let partLabel = parts.count > 1 ? "Audio \(i + 1)/\(parts.count) · " : ""
                    let base = Double(i) / Double(parts.count)
                    let social = Engine.socialFolder(project: project, partIndex: i + 1, partCount: parts.count, part: part)
                    let outputs = try await engine.render(project: project, analysis: analysis!, plan: plan, folder: folder,
                                                          clipFolder: social,
                                                          alternativesFolders: Engine.alternativeFolders(project: project, partIndex: i + 1, partCount: parts.count, part: part)) { [weak self] title, fraction in
                        Task { @MainActor in
                            self?.status = "\(partLabel)\(title)"
                            self?.progress = base + fraction / Double(parts.count)
                        }
                    }
                    written += outputs.map(\.url)
                    lastOutputs = written
                }
                engine.releaseMemory()
                let seconds = Date().timeIntervalSince(started)
                status = String(format: "Exported %d video%@ in %@.", written.count, written.count == 1 ? "" : "s", Self.duration(seconds))
                append(status)
                NSApp.requestUserAttention(.informationalRequest)
            } catch is CancellationError {
                status = "Export cancelled. Finished videos were kept."
            } catch {
                errorMessage = error.localizedDescription
                status = "Export needs attention."
            }
            phase = .idle
            progress = nil
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    func revealOutputs() {
        if lastOutputs.isEmpty {
            let folder = URL(fileURLWithPath: (project.outputDir as NSString).expandingTildeInPath)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(lastOutputs)
        }
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? String(format: "%.0f s", seconds) : String(format: "%d min %02d s", Int(seconds) / 60, Int(seconds) % 60)
    }
}
