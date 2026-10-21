import AVFoundation
import Foundation

/// Everything measured for one audio excerpt: sync, music and picture scores.
public struct PartAnalysis: Sendable {
    public var part: AudioPart
    public var bounce: MediaInfo
    public var music: MusicInfo
    public var clips: [SyncedClip]               // synced recordings only
    public var vision: [VisionScores?]           // aligned with clips
    public var waveform: [Float]                 // 0-1 peaks for display
    public var warnings: [String]
    public var duration: Double { bounce.duration }

    public func frames(fps: Int) -> Int { Int((duration * Double(fps) - 1e-8).rounded(.up)) }

    /// Coverage of each clip on the frame grid for `fps`.
    public func coverage(fps: Int) -> [Coverage] {
        let total = frames(fps: fps), f = Double(fps)
        return clips.map { c in
            let first = max(0, min(total, Int((c.sync.offset * f - 1e-7).rounded(.up))))
            let end = c.sync.offset + c.sync.rate * c.info.duration
            var last = max(0, min(total, Int((end * f + 1e-7).rounded(.down))))
            if end >= duration - 1e-7 { last = total }
            return Coverage(angle: c.cameraID, first: first, last: last)
        }
    }

    /// Picture scores on the bounce timeline in 0.5 s steps.
    public func scores(fps: Int) -> [CameraScores] {
        let total = frames(fps: fps)
        let steps = Planner.steps(total: total, fps: fps)
        let cover = coverage(fps: fps)
        let mapped: [([Double?], [Double?])?] = clips.indices.map { i in
            guard let v = vision[i], v.times.count >= 2 else { return nil }
            var usable = [Double?](repeating: nil, count: steps), activity = usable
            let c = clips[i]
            var j = 0
            for k in 0..<steps {
                let t = (Double(k) + 0.5) * ScoreTrack.step
                let frame = t * Double(fps)
                guard Double(cover[i].first) <= frame && frame < Double(cover[i].last) else { continue }
                let source = (t - c.sync.offset) / c.sync.rate + c.info.videoStart
                while j + 1 < v.times.count && v.times[j + 1] < source { j += 1 }
                let a = j, b = min(j + 1, v.times.count - 1)
                let span = v.times[b] - v.times[a]
                let w = span > 0 ? min(1, max(0, (source - v.times[a]) / span)) : 0
                usable[k] = v.usable[a] + (v.usable[b] - v.usable[a]) * w
                activity[k] = v.activity[a] + (v.activity[b] - v.activity[a]) * w
            }
            return (usable, activity)
        }
        return Planner.scores(steps: steps, vision: mapped)
    }
}

public struct PlannedClip: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var window: ClipWindow
    public var shots: [Shot]
}

public struct EditPlan: Sendable {
    public var shots: [Shot]
    public var clips: [PlannedClip]
    public var sections: [MusicInfo.Section]
    public var total: Int
    public var fps: Int
}

public struct RenderedOutput: Sendable, Hashable {
    public var url: URL
    public var kind: String          // "full" or "clip"
    public var start: Double
    public var end: Double
}

/// Orchestrates analysis, planning and rendering. Used by the app and the mcstudio tool.
public final class Engine: @unchecked Sendable {
    public var log: (String) -> Void
    public var status: (String, Double?) -> Void
    public let cacheDirectory: URL
    private var sampleCache = [String: [Float]]()
    private let lock = NSLock()

    public init(cacheDirectory: URL = Cache.directory, log: @escaping (String) -> Void = { print($0) },
                status: @escaping (String, Double?) -> Void = { _, _ in }) {
        self.cacheDirectory = cacheDirectory
        self.log = log
        self.status = status
    }

    // MARK: analysis

    func identity(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(url.standardizedFileURL.path):\(values?.fileSize ?? 0):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    func cached<T: Codable>(_ name: String, _ make: () async throws -> T) async rethrows -> T {
        let file = cacheDirectory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(T.self, from: data) { return value }
        let value = try await make()
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(value).write(to: file, options: .atomic)
        return value
    }

    func syncSamples(_ url: URL) async throws -> [Float] {
        let key = url.standardizedFileURL.path
        if let samples = lock.withLock({ sampleCache[key] }) { return samples }
        let samples = try await AudioSync.analysisAudio(url)
        lock.withLock { sampleCache[key] = samples }
        return samples
    }

    /// Forget decoded camera audio (call after a batch of excerpts).
    public func releaseMemory() { lock.withLock { sampleCache.removeAll() } }

    public func analyse(project: Project, part: AudioPart, vision useVision: Bool = true) async throws -> PartAnalysis {
        let bounceURL = URL(fileURLWithPath: part.path)
        status("Reading \(bounceURL.lastPathComponent)", nil)
        let bounce = try await Media.info(bounceURL)
        log("Audio: \(bounceURL.lastPathComponent) (\(Timecode.short(bounce.duration)))")
        status("Analysing the music", nil)
        let raw = try await Media.decodeAudio(bounceURL, sampleRate: 8000)
        let music = await cached("music-\(Cache.key("v1:" + identity(bounceURL))).json") { MusicAnalysis.analyse(raw, duration: bounce.duration) }
        if let bpm = music.bpm {
            log(String(format: "Music: %.1f BPM, beat confidence %.0f%%, %d drops", bpm, music.confidence * 100, music.drops.count))
        }
        let waveform = Self.peaks(raw, count: 4000)
        var reference = raw
        Biquad.apply(&reference, highpass: 120, lowpass: 3000, sampleRate: 8000)
        var clips = [SyncedClip](), warnings = [String]()
        var manual = [String: (Double, Double)]()
        for o in part.overrides { if let offset = o.offset, manual[o.path] == nil { manual[o.path] = (offset, o.driftPPM ?? 0) } }
        let total = project.cameras.flatMap(\.clips).count
        var done = 0
        for camera in project.cameras {
            for clip in camera.clips {
                done += 1
                let url = clip.url
                status("Syncing \(url.lastPathComponent) (\(done)/\(total))", Double(done - 1) / Double(max(1, total)))
                do {
                    let info = try await Media.info(url)
                    guard info.hasVideo else { throw MulticamError("\(url.lastPathComponent) has no video.") }
                    let sync: SyncResult
                    if let (offset, ppm) = manual[clip.path] {
                        sync = SyncResult(offset: offset, rate: 1 + ppm / 1e6, matchedAnchors: nil, method: "manual")
                        log("\(url.lastPathComponent): manual sync \(String(format: "%+.3f", offset)) s")
                    } else {
                        guard info.hasAudio else { throw MulticamError("\(url.lastPathComponent) has no audio; set a manual offset.") }
                        let key = "sync-\(Cache.key("v1:\(identity(url))|\(identity(bounceURL))|\(project.drift)")).json"
                        sync = try await cached(key) {
                            log("Syncing \(url.lastPathComponent) …")
                            let samples = try await syncSamples(url)
                            return try AudioSync.synchronise(camera: samples, info: info, bounce: reference,
                                                             allowDrift: project.drift, log: log)
                        }
                        log(String(format: "%@: offset %+.3f s, drift %+.2f ppm (%d anchors)", url.lastPathComponent,
                                   sync.offset, sync.driftPPM, sync.matchedAnchors ?? 0))
                    }
                    let end = sync.offset + sync.rate * info.duration
                    if end <= 0 || sync.offset >= bounce.duration {
                        warnings.append("\(camera.id) / \(url.lastPathComponent) has no footage during this audio.")
                        continue
                    }
                    clips.append(SyncedClip(cameraID: camera.id, label: camera.label, url: url, info: info,
                                            framing: clip.framing, sync: sync, focus: nil,
                                            coverage: Coverage(angle: camera.id, first: 0, last: 0)))
                } catch let error as CancellationError {
                    throw error
                } catch {
                    let message = "\(camera.id) / \(url.lastPathComponent): left out because sync could not be verified. \(error.localizedDescription)"
                    warnings.append(message)
                    log("WARNING: " + message)
                }
            }
        }
        guard !clips.isEmpty else {
            throw MulticamError("No camera could be synced to \(bounceURL.lastPathComponent). Check the footage overlaps this audio, or set manual offsets.")
        }
        var vision = [VisionScores?](repeating: nil, count: clips.count)
        if useVision {
            status("Scoring camera pictures", 0)
            try await withThrowingTaskGroup(of: (Int, VisionScores).self) { group in
                for (i, clip) in clips.enumerated() {
                    group.addTask { [cacheDirectory] in (i, try await VisionAnalysis.analyse(clip.url, cacheDirectory: cacheDirectory)) }
                }
                var finished = 0
                for try await (i, scores) in group {
                    vision[i] = scores
                    clips[i].focus = scores.focus
                    finished += 1
                    status("Scoring camera pictures", Double(finished) / Double(clips.count))
                }
            }
        }
        return PartAnalysis(part: part, bounce: bounce, music: music, clips: clips, vision: vision,
                            waveform: waveform, warnings: warnings)
    }

    static func peaks(_ samples: [Float], count: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let n = min(count, samples.count)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = samples.count * i / n, b = max(a + 1, samples.count * (i + 1) / n)
            var sum: Float = 0
            for j in a..<b { sum += samples[j] * samples[j] }
            out[i] = (sum / Float(b - a)).squareRoot()
        }
        let top = max(out.max() ?? 1, 1e-9)
        return out.map { $0 / top }
    }

    // MARK: planning

    public static func sections(project: Project, part: AudioPart, music: MusicInfo) -> [MusicInfo.Section] {
        if !part.drops.isEmpty || !part.breakdowns.isEmpty {
            return (part.drops.filter { $0.count == 2 }.map { MusicInfo.Section(start: $0[0], end: $0[1], kind: "drop") }
                + part.breakdowns.filter { $0.count == 2 }.map { MusicInfo.Section(start: $0[0], end: $0[1], kind: "breakdown") })
                .sorted { $0.start < $1.start }
        }
        guard project.autoSections, music.hasGrid else { return [] }
        return music.sections.filter { $0.kind != "normal" }
    }

    public static func plan(project: Project, analysis: PartAnalysis) throws -> EditPlan {
        let fps = project.fps
        let total = analysis.frames(fps: fps)
        let cover = analysis.coverage(fps: fps)
        let scores = analysis.scores(fps: fps)
        let sections = sections(project: project, part: analysis.part, music: analysis.music)
        var rhythm = Rhythm()
        func pair(_ v: [Double], _ d: (Double, Double)) -> (Double, Double) { v.count == 2 ? (v[0], v[1]) : d }
        rhythm.mainHold = pair(project.mainHold, (20, 60)); rhythm.cutawayHold = pair(project.cutawayHold, (4, 12))
        rhythm.dropHold = pair(project.dropHold, (3, 6)); rhythm.breakdownHold = pair(project.breakdownHold, (15, 30))
        rhythm.cutScale = project.cutScale; rhythm.mainShare = project.mainShare
        let ids = Set(cover.map(\.angle))
        let main = ids.contains(project.mainCamera) ? project.mainCamera : cover[0].angle
        var shots = Planner.plan(cameras: cover, total: total, fps: fps, music: analysis.music, sections: sections,
                                 activities: analysis.part.activities, seed: project.seed, mainCamera: main,
                                 rhythm: rhythm, scores: scores)
        shots = try Planner.applyOverrides(shots, cameras: cover, paths: analysis.clips.map(\.url.path),
                                           overrides: analysis.part.shotOverrides, fps: fps, duration: analysis.duration)
        var clips = [PlannedClip]()
        if project.clips > 0 {
            let windows = Planner.windows(music: analysis.music, cameras: cover, total: total, fps: fps,
                                          length: project.clips, scores: scores)
            let chosen = Planner.choose(windows, count: project.clipCount, mode: project.clipMode)
            var short = Rhythm.shortForm
            short.cutScale = project.cutScale
            let forced = shots.filter { $0.reason == "manual shot override" }
            for (i, w) in chosen.enumerated() {
                let range = Int((w.start * Double(fps)).rounded())..<Int((w.end * Double(fps)).rounded())
                var plan = Planner.plan(cameras: cover, total: total, fps: fps, music: analysis.music, sections: sections,
                                        activities: analysis.part.activities, seed: project.seed + i + 1, mainCamera: main,
                                        rhythm: short, window: range, scores: scores)
                plan = Planner.overlay(plan, forced: forced, start: range.lowerBound, end: range.upperBound)
                clips.append(PlannedClip(index: i + 1, window: w, shots: plan))
            }
        }
        return EditPlan(shots: shots, clips: clips, sections: sections, total: total, fps: fps)
    }

    // MARK: rendering

    public static func baseName(_ project: Project) -> String {
        let name = project.outputName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        return project.aspect == .portrait ? "multicam_cut_vertical" : "multicam_cut"
    }

    public static func outputFolder(project: Project, partIndex: Int, partCount: Int, part: AudioPart) -> URL {
        let root = URL(fileURLWithPath: (project.outputDir as NSString).expandingTildeInPath, isDirectory: true)
        guard partCount > 1 else { return root }
        let stem = URL(fileURLWithPath: part.path).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        return root.appendingPathComponent(String(format: "part_%03d_%@", partIndex, String(stem.prefix(40))), isDirectory: true)
    }

    public static func clipName(_ base: String, _ index: Int, _ start: Double, _ ext: String) -> String {
        let s = Int(start)
        return String(format: "%@_%03d_%02d-%02d-%02d.%@", base, index, s / 3600, s / 60 % 60, s % 60, ext)
    }

    /// Planned output files, so existing files can be checked before anything renders.
    public static func outputs(project: Project, plan: EditPlan, folder: URL) -> [RenderedOutput] {
        let base = baseName(project), ext = project.codec.fileExtension
        var result = [RenderedOutput]()
        if project.fullEdit {
            result.append(RenderedOutput(url: folder.appendingPathComponent("\(base).\(ext)"), kind: "full",
                                         start: 0, end: Double(plan.total) / Double(plan.fps)))
        }
        let clipFolder = folder.appendingPathComponent("\(base)_clips", isDirectory: true)
        for clip in plan.clips {
            result.append(RenderedOutput(url: clipFolder.appendingPathComponent(clipName(base, clip.index, clip.window.start, ext)),
                                         kind: "clip", start: clip.window.start, end: clip.window.end))
        }
        return result
    }

    public func render(project: Project, analysis: PartAnalysis, plan: EditPlan, folder: URL,
                       progress: @escaping @Sendable (String, Double) -> Void) async throws -> [RenderedOutput] {
        let planned = Self.outputs(project: project, plan: plan, folder: folder)
        if !project.overwrite, let existing = planned.first(where: { FileManager.default.fileExists(atPath: $0.url.path) }) {
            throw MulticamError("\(existing.url.lastPathComponent) already exists. Turn on “Replace existing files” or choose another folder or name.")
        }
        let inputs = Set(analysis.clips.map { $0.url.standardizedFileURL } + [URL(fileURLWithPath: analysis.part.path).standardizedFileURL])
        if let clash = planned.first(where: { inputs.contains($0.url.standardizedFileURL) }) {
            throw MulticamError("\(clash.url.lastPathComponent) would overwrite a recording. Choose another output folder or name.")
        }
        let weights = planned.map { $0.end - $0.start }
        let totalWeight = max(0.001, weights.reduce(0, +))
        var doneWeight = 0.0
        var rendered = [RenderedOutput]()
        let bounce = URL(fileURLWithPath: analysis.part.path)
        for (n, output) in planned.enumerated() {
            try Task.checkCancellation()
            let isFull = output.kind == "full"
            let clip = isFull ? nil : plan.clips.first { $0.window.start == output.start }
            let size = isFull ? project.aspect.size(resolution: project.resolution)
                              : project.clipAspect.size(resolution: project.clipResolution)
            let spec = OutputSpec(width: size.width, height: size.height, fps: plan.fps, codec: project.codec,
                                  crf: project.crf, look: project.look)
            let window = isFull ? 0..<plan.total
                : Int((output.start * Double(plan.fps)).rounded())..<Int((output.end * Double(plan.fps)).rounded())
            let title = isFull ? "Full edit" : "Clip \(clip!.index) of \(plan.clips.count)"
            log("\(title): \(size.width)x\(size.height) \(project.codec.rawValue.uppercased()) → \(output.url.lastPathComponent)")
            let started = Date()
            let edit = try await Renderer.prepare(shots: isFull ? plan.shots : clip!.shots, clips: analysis.clips,
                                                  bounce: bounce, window: window, spec: spec,
                                                  audioFade: isFull ? 0 : project.clipFade, declick: isFull ? 0 : 0.015)
            let base = doneWeight, weight = weights[n]
            try await Renderer.export(edit, to: output.url, spec: spec) { fraction in
                progress(title, (base + fraction * weight) / totalWeight)
            }
            let seconds = Date().timeIntervalSince(started)
            log(String(format: "  done in %.1f s (%.1f× real time)", seconds, (output.end - output.start) / max(seconds, 0.01)))
            doneWeight += weight
            rendered.append(output)
        }
        return rendered
    }

    // MARK: reports

    public static func cutList(project: Project, analysis: PartAnalysis, plan: EditPlan) -> String {
        let f = Double(plan.fps)
        var lines = ["Multicam Studio cut list — \(URL(fileURLWithPath: analysis.part.path).lastPathComponent)",
                     "Seed \(project.seed); \(plan.fps) fps; main camera \(project.mainCamera)"]
        if let bpm = analysis.music.bpm { lines.append(String(format: "Music: %.1f BPM, beat confidence %.0f%%", bpm, analysis.music.confidence * 100)) }
        for c in analysis.clips {
            lines.append(String(format: "SYNC %@ %@: offset %+.6f s, drift %+.2f ppm (%@)", c.cameraID, c.url.path, c.sync.offset, c.sync.driftPPM, c.sync.method))
        }
        lines += analysis.warnings.map { "WARNING: " + $0 }
        lines += ["", "#     IN -> OUT                      | ANGLE | FILE | REASON"]
        for (n, s) in plan.shots.enumerated() {
            let name = s.camera.map { analysis.clips[$0].cameraID + " | " + analysis.clips[$0].url.lastPathComponent } ?? "BLACK | -"
            lines.append(String(format: "%04d  %@ -> %@ | %@ | %@", n + 1, Timecode.format(Double(s.start) / f),
                                Timecode.format(min(analysis.duration, Double(s.end) / f)), name, s.reason))
        }
        for clip in plan.clips {
            lines += ["", "Clip \(clip.index): \(Timecode.format(clip.window.start)) -> \(Timecode.format(clip.window.end))"]
            for s in clip.shots {
                let name = s.camera.map { analysis.clips[$0].cameraID } ?? "BLACK"
                lines.append("  \(Timecode.format(Double(s.start) / f - clip.window.start)) \(name) \(s.reason)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
