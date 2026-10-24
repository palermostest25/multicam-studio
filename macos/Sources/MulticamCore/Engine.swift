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
    public var excluded: [ExcludedClip] = []
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

/// A recording left out of one excerpt, and why.
public struct ExcludedClip: Sendable, Hashable {
    public var path: String
    public var cameraID: String
    public var noFootage: Bool          // the camera wasn't recording during this audio
    public var message: String
    public var suggestedOffset: Double? // from the recording clocks, about ±1 s
}

public struct PlannedClip: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int            // unique across all lengths
    public var number: Int           // 1, 2, 3… within its length
    public var length: Double        // requested length in seconds
    public var window: ClipWindow
    public var shots: [Shot]
    public var look: Look.Style = .none
    public var label: String { "\(Int(length.rounded())) s #\(number)" + (look == .none ? "" : " · \(look.title)") }
}

public struct EditPlan: Sendable {
    public var shots: [Shot]
    public var clips: [PlannedClip]
    public var sections: [MusicInfo.Section]
    public var total: Int
    public var fps: Int
    /// The excerpt and synced recordings this plan was made for. Shot camera indices
    /// point into exactly that analysis, so a plan must never be paired with another.
    public var partPath: String = ""
    public var clipCount: Int = 0

    public func matches(_ analysis: PartAnalysis?) -> Bool {
        guard let analysis else { return false }
        return analysis.part.path == partPath && analysis.clips.count == clipCount
    }
}

public struct RenderedOutput: Sendable, Hashable {
    public var url: URL
    public var kind: String          // "full", "clip" or "alternative"
    public var start: Double
    public var end: Double
    public var clipIndex: Int? = nil
    public var aspect: Aspect? = nil      // alternatives: the shape of this copy
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
        var failed = [(camera: CameraDefinition, url: URL, info: MediaInfo?, error: String)]()
        var excluded = [ExcludedClip]()
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
                        excluded.append(ExcludedClip(path: url.path, cameraID: camera.id, noFootage: true,
                                                     message: "No footage during this audio.", suggestedOffset: nil))
                        continue
                    }
                    clips.append(SyncedClip(cameraID: camera.id, label: camera.label, url: url, info: info,
                                            framing: clip.framing, sync: sync, focus: nil,
                                            coverage: Coverage(angle: camera.id, first: 0, last: 0)))
                } catch let error as CancellationError {
                    throw error
                } catch {
                    failed.append((camera, url, try? await Media.info(url), error.localizedDescription))
                }
            }
        }
        // Recording clocks place every camera on one timeline: tell "wasn't recording" apart from
        // "couldn't sync", and retry a failed sync only around where the clocks say it overlaps.
        let anchorClip = clips.filter { $0.info.creationDate != nil && $0.sync.method != "manual" }
            .max { ($0.coverage.last - $0.coverage.first) < ($1.coverage.last - $1.coverage.first) }
            ?? clips.first { $0.info.creationDate != nil }
        let audioStart = anchorClip.map { $0.info.creationDate!.addingTimeInterval(-$0.sync.offset) }
        for item in failed {
            var expected: Double?
            if let audioStart, let date = item.info?.creationDate { expected = date.timeIntervalSince(audioStart) }
            if let expected, let info = item.info {
                if expected + info.duration < -5 || expected > bounce.duration + 5 {
                    let gap = expected > 0 ? expected - bounce.duration : -(expected + info.duration)
                    excluded.append(ExcludedClip(path: item.url.path, cameraID: item.camera.id, noFootage: true,
                                                 message: "No footage during this audio (the recording \(expected > 0 ? "starts" : "ended") \(Timecode.short(max(0, gap))) \(expected > 0 ? "after it ends" : "before it starts")).",
                                                 suggestedOffset: nil))
                    log("\(item.url.lastPathComponent): not recording during this audio (by the camera clocks)")
                    continue
                }
                if info.hasAudio, let sync = try? await guidedSync(url: item.url, info: info,
                                                                    expected: expected, bounceAudio: reference, duration: bounce.duration,
                                                                    allowDrift: project.drift) {
                    log(String(format: "%@: offset %+.3f s (search guided by the recording clocks)", item.url.lastPathComponent, sync.offset))
                    clips.append(SyncedClip(cameraID: item.camera.id, label: item.camera.label, url: item.url, info: info,
                                            framing: item.camera.clips.first { $0.path == item.url.path }?.framing ?? Framing(),
                                            sync: sync, focus: nil, coverage: Coverage(angle: item.camera.id, first: 0, last: 0)))
                    continue
                }
            }
            let message = "\(item.camera.id) / \(item.url.lastPathComponent): left out because sync could not be verified. "
                + (expected.map { String(format: "The camera clocks suggest an offset near %+.1f s; set it as a manual offset and fine-tune. ", $0) } ?? "")
                + item.error
            warnings.append(message)
            excluded.append(ExcludedClip(path: item.url.path, cameraID: item.camera.id, noFootage: false,
                                         message: "Couldn't sync to this audio.", suggestedOffset: expected))
            log("WARNING: " + message)
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
        var analysis = PartAnalysis(part: part, bounce: bounce, music: music, clips: clips, vision: vision,
                                    waveform: waveform, warnings: warnings)
        analysis.excluded = excluded
        return analysis
    }

    /// Correlate only the stretch of camera audio the recording clocks point to (±20 s).
    func guidedSync(url: URL, info: MediaInfo, expected: Double, bounceAudio: [Float],
                    duration: Double, allowDrift: Bool) async throws -> SyncResult {
        let samples = try await syncSamples(url)
        let sr = AudioSync.sampleRate
        let from = max(0, -expected - 20), to = min(Double(samples.count) / sr, -expected + duration + 20)
        guard to - from > 6 else { throw MulticamError("Too little overlap") }
        let slice = Array(samples[Int(from * sr)..<min(samples.count, Int(to * sr))])
        var result = try AudioSync.synchronise(camera: slice, info: info, bounce: bounceAudio, allowDrift: allowDrift)
        result.offset -= result.rate * from   // slice time 0 is camera time `from`
        result.method = "automatic"
        return result
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
        var short = Rhythm.shortForm
        short.cutScale = project.cutScale
        let forced = shots.filter { $0.reason == "manual shot override" }
        for length in project.socialLengths {
            let windows = Planner.windows(music: analysis.music, cameras: cover, total: total, fps: fps,
                                          length: length, scores: scores, ending: project.engine.clipEnding,
                                          excludes: analysis.part.clipExcludes)
            let chosen = Planner.choose(windows, count: project.clipCount, mode: project.clipMode)
            for (i, w) in chosen.enumerated() {
                let range = Int((w.start * Double(fps)).rounded())..<Int((w.end * Double(fps)).rounded())
                let serial = clips.count + 1
                var plan = Planner.plan(cameras: cover, total: total, fps: fps, music: analysis.music, sections: sections,
                                        activities: analysis.part.activities, seed: project.seed + serial, mainCamera: main,
                                        rhythm: short, window: range, scores: scores)
                plan = Planner.overlay(plan, forced: forced, start: range.lowerBound, end: range.upperBound)
                clips.append(PlannedClip(index: serial, number: i + 1, length: length, window: w, shots: plan))
            }
        }
        for (i, look) in Self.assignClipLooks(clips, mode: project.clipFilters, seed: project.seed).enumerated() {
            clips[i].look = look
        }
        return EditPlan(shots: shots, clips: clips, sections: sections, total: total, fps: fps,
                        partPath: analysis.part.path, clipCount: analysis.clips.count)
    }

    // MARK: rendering

    /// Export layout (the output folder is the export root, shared by every audio part):
    ///   Full sets/<set>.mp4
    ///   Social media/<set>/<L>s/<set> - <L>s - 01 - 3m39s.mp4
    ///   Social media alternatives/<shape>/<set>/<L>s/…
    ///   Project files/<set>/Cut list.txt
    /// Mirrors FULL_FOLDER/SOCIAL_FOLDER/ALTERNATIVES_FOLDER/FILES_FOLDER in multicam_edit.py.
    public static let fullFolderName = "Full sets"
    public static let socialFolderName = "Social media"
    public static let filesFolderName = "Project files"
    /// Black-bar copies of the clips that use a vertical recording (see alternativeSources):
    /// a 16:9 copy with bars beside the vertical shots, and a 9:16 copy with bars above and below the wide ones.
    public static let alternativesFolderName = "Social media alternatives"
    public static let alternativeShapes: [Aspect] = [.landscape, .portrait]
    public static func alternativeFolderName(_ shape: Aspect) -> String {
        shape == .portrait ? "Vertical (bars on wide shots)" : "Landscape (bars on vertical shots)"
    }

    /// A tidy file/folder name: letters, digits, spaces and ._- only (same rule as readable_name in Python).
    public static func readableName(_ text: String, fallback: String = "Set") -> String {
        let cleaned = text.replacingOccurrences(of: "[^A-Za-z0-9 ._-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        let name = String(cleaned.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return name.first.map { $0.isLetter || $0.isNumber } == true ? name : fallback
    }

    /// The set's name: your file name (plus "- Part N" with several excerpts) or the audio file's name.
    public static func setName(project: Project, partIndex: Int, partCount: Int, part: AudioPart) -> String {
        let custom = readableName(project.outputName.replacingOccurrences(of: "\\.(mp4|mov)$", with: "", options: [.regularExpression, .caseInsensitive]), fallback: "")
        if !custom.isEmpty { return partCount > 1 ? "\(custom) - Part \(partIndex)" : custom }
        let stem = readableName(URL(fileURLWithPath: part.path).deletingPathExtension().lastPathComponent)
        let name = project.aspect == .portrait ? "\(stem) vertical" : stem
        // Two excerpts with the same file name still get their own files.
        let earlier = project.parts.prefix(max(0, partIndex - 1)).map {
            readableName(URL(fileURLWithPath: $0.path).deletingPathExtension().lastPathComponent).lowercased()
        }
        return earlier.contains(stem.lowercased()) ? "\(name) (\(partIndex))" : name
    }

    public struct ExportPaths: Sendable {
        public var root: URL
        public var setName: String
        public init(root: URL, setName: String) { self.root = root; self.setName = setName }
        public func fullVideo(_ ext: String) -> URL {
            root.appendingPathComponent(Engine.fullFolderName, isDirectory: true).appendingPathComponent("\(setName).\(ext)")
        }
        public var files: URL {
            root.appendingPathComponent(Engine.filesFolderName, isDirectory: true).appendingPathComponent(setName, isDirectory: true)
        }
        public var social: URL {
            root.appendingPathComponent(Engine.socialFolderName, isDirectory: true).appendingPathComponent(setName, isDirectory: true)
        }
        public func alternatives(_ shape: Aspect) -> URL {
            root.appendingPathComponent(Engine.alternativesFolderName, isDirectory: true)
                .appendingPathComponent(Engine.alternativeFolderName(shape), isDirectory: true)
                .appendingPathComponent(setName, isDirectory: true)
        }
    }

    public static func exportPaths(project: Project, partIndex: Int, partCount: Int, part: AudioPart) -> ExportPaths {
        ExportPaths(root: URL(fileURLWithPath: (project.outputDir as NSString).expandingTildeInPath, isDirectory: true),
                    setName: setName(project: project, partIndex: partIndex, partCount: partCount, part: part))
    }

    /// "<set> - 15s - 01 - 3m39s.mp4": sorts by length, then number, and says where it starts.
    public static func clipName(_ base: String, _ clip: PlannedClip, _ ext: String) -> String {
        let s = Int(clip.window.start), h = s / 3600, m = s / 60 % 60, sec = s % 60
        let stamp = h > 0 ? String(format: "%dh%02dm%02ds", h, m, sec) : String(format: "%dm%02ds", m, sec)
        return String(format: "%@ - %ds - %02d - %@.%@", base, Int(clip.length.rounded()), clip.number, stamp, ext)
    }

    /// The synced recordings with the project's *current* framing. Analysis captures framing when it
    /// runs; framing edited afterwards must still reach the preview and the export.
    public static func currentSources(_ analysis: PartAnalysis, project: Project) -> [SyncedClip] {
        var framing = [String: Framing]()
        for camera in project.cameras { for clip in camera.clips { framing[clip.path] = clip.framing } }
        return analysis.clips.map { clip in
            var c = clip
            if let f = framing[clip.url.path] { c.framing = f }
            return c
        }
    }

    public static let greyscaleLooks: [Look.Style] = [.noir, .silver]
    public static let colourMix: [Look.Style] = [.none, .vivid, .vintage, .warm, .super8, .faded]

    /// Looks for social clips. "auto": about a third of the clips (the calmest) black and white,
    /// alternating Noir and Silver; the rest rotate through colourMix in time order.
    /// Mirrors looks.assign_clip_looks in Python.
    public static func assignClipLooks(_ clips: [PlannedClip], mode: String, seed: Int) -> [Look.Style] {
        if mode.isEmpty || mode == "off" { return Array(repeating: .none, count: clips.count) }
        if mode != "auto" { return Array(repeating: Look.Style(rawValue: mode) ?? .none, count: clips.count) }
        let n = clips.count
        var looks = [Look.Style](repeating: .none, count: n)
        let grey = n >= 2 ? Int((Double(n) / 3).rounded()) : 0
        let calm = Array(clips.indices.sorted {
            (clips[$0].window.score, clips[$0].window.start, $0) < (clips[$1].window.score, clips[$1].window.start, $1)
        }.prefix(grey))
        for (rank, i) in calm.enumerated() { looks[i] = greyscaleLooks[rank % greyscaleLooks.count] }
        let colour = clips.indices.filter { !calm.contains($0) }.sorted { (clips[$0].window.start, $0) < (clips[$1].window.start, $1) }
        for (k, i) in colour.enumerated() { looks[i] = colourMix[(seed + k) % colourMix.count] }
        return looks
    }

    /// The look a clip renders with: the project's look, with the clip's filter as its colour style.
    public static func clipLook(_ clip: PlannedClip, project: Project) -> Look {
        var look = project.look
        if project.clipFilters != "off" { look.style = clip.look }
        return look
    }

    /// A clip that lands on the beat fades over the last part of its final beat, so it finishes cleanly.
    public static func clipFadeOut(_ window: ClipWindow) -> Double { window.tail * 0.6 }

    /// Social media alternatives: recordings shaped like the copy fill it (zoom 1),
    /// every other recording is shown whole with black bars.
    public static func alternativeSources(_ clips: [SyncedClip], shape: Aspect) -> [SyncedClip] {
        let (w, h) = shape.ratio
        let target = Double(w) / Double(h)
        return clips.map { clip in
            var c = clip
            if min(target, clip.info.aspect) / max(target, clip.info.aspect) >= 0.55 {
                c.framing.mode = .crop; c.framing.zoom = 1; c.framing.auto = true
            } else {
                c.framing.mode = .pad
            }
            return c
        }
    }

    /// Indices of the vertical recordings, as used by `Shot.camera`.
    public static func verticalCameras(_ analysis: PartAnalysis) -> Set<Int> {
        Set(analysis.clips.indices.filter { analysis.clips[$0].info.aspect < 1 })
    }

    /// Recordings as framed in short clips (see ClipFraming).
    public static func clipSources(_ clips: [SyncedClip], aspect: Aspect, mode: ClipFraming) -> [SyncedClip] {
        clips.map { clip in
            var c = clip
            c.framing = clipFraming(clip.framing, info: clip.info, aspect: aspect, mode: mode)
            return c
        }
    }

    public static func clipFraming(_ f: Framing, info: MediaInfo, aspect: Aspect, mode: ClipFraming) -> Framing {
        var crop = f
        crop.mode = .crop
        if f.mode != .crop { crop.auto = true; crop.zoom = 1 }
        var fit = f
        fit.mode = .fit
        switch mode {
        case .same: return f
        case .fit: return fit
        case .bars: var bars = f; bars.mode = .pad; return bars
        case .crop: return crop
        case .smart:
            // Share of the source picture a zoom-1 crop keeps: crop only near-matching shapes.
            let (w, h) = aspect.ratio
            let target = Double(w) / Double(h), source = info.aspect
            let kept = min(target, source) / max(target, source)
            return kept >= 0.55 ? (f.mode == .pad ? f : crop) : fit
        }
    }

    /// Planned output files, so existing files can be checked before anything renders.
    public static func outputs(project: Project, plan: EditPlan, paths: ExportPaths, vertical: Set<Int> = []) -> [RenderedOutput] {
        let base = paths.setName, ext = project.codec.fileExtension
        var result = [RenderedOutput]()
        if project.fullEdit {
            result.append(RenderedOutput(url: paths.fullVideo(ext), kind: "full",
                                         start: 0, end: Double(plan.total) / Double(plan.fps)))
        }
        let clipFolder = paths.social
        for clip in plan.clips {
            let lengthFolder = clipFolder.appendingPathComponent("\(Int(clip.length.rounded()))s", isDirectory: true)
            result.append(RenderedOutput(url: lengthFolder.appendingPathComponent(clipName(base, clip, ext)),
                                         kind: "clip", start: clip.window.start, end: clip.window.end, clipIndex: clip.index))
        }
        if project.clipAlternatives && !vertical.isEmpty {
            for shape in alternativeShapes {
                let altFolder = paths.alternatives(shape)
                for clip in plan.clips where clip.shots.contains(where: { $0.camera.map(vertical.contains) ?? false }) {
                    let lengthFolder = altFolder.appendingPathComponent("\(Int(clip.length.rounded()))s", isDirectory: true)
                    result.append(RenderedOutput(url: lengthFolder.appendingPathComponent(clipName(base, clip, ext)),
                                                 kind: "alternative", start: clip.window.start, end: clip.window.end,
                                                 clipIndex: clip.index, aspect: shape))
                }
            }
        }
        return result
    }

    public func render(project: Project, analysis: PartAnalysis, plan: EditPlan, paths: ExportPaths,
                       progress: @escaping @Sendable (String, Double) -> Void) async throws -> [RenderedOutput] {
        let planned = Self.outputs(project: project, plan: plan, paths: paths, vertical: Self.verticalCameras(analysis))
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
            let isFull = output.kind == "full", isAlternative = output.kind == "alternative"
            let clip = isFull ? nil : plan.clips.first { $0.index == output.clipIndex }
            let size = isFull ? project.aspect.size(resolution: project.resolution)
                : (isAlternative ? output.aspect ?? .portrait : project.clipAspect).size(resolution: project.clipResolution)
            let spec = OutputSpec(width: size.width, height: size.height, fps: plan.fps, codec: project.codec,
                                  crf: project.crf, look: isFull ? project.look : Self.clipLook(clip!, project: project))
            let window = isFull ? 0..<plan.total
                : Int((output.start * Double(plan.fps)).rounded())..<Int((output.end * Double(plan.fps)).rounded())
            let title = isFull ? "Full edit"
                : "\(isAlternative ? "Alternative \((output.aspect ?? .portrait).rawValue)" : "Clip") \(clip!.index) of \(plan.clips.count) (\(clip!.label))"
            log("\(title): \(size.width)x\(size.height) \(project.codec.rawValue.uppercased()) → \(output.url.lastPathComponent)")
            let started = Date()
            let current = Self.currentSources(analysis, project: project)
            let sources = isFull ? current
                : isAlternative ? Self.alternativeSources(current, shape: output.aspect ?? .portrait)
                : Self.clipSources(current, aspect: project.clipAspect, mode: project.clipFraming)
            let edit = try await Renderer.prepare(shots: isFull ? plan.shots : clip!.shots, clips: sources,
                                                  bounce: bounce, window: window, spec: spec,
                                                  audioFade: isFull ? 0 : project.clipFade, declick: isFull ? 0 : 0.015,
                                                  audioFadeOut: isFull ? 0 : Self.clipFadeOut(clip!.window))
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
            let name = s.camera.flatMap { analysis.clips.indices.contains($0) ? analysis.clips[$0].cameraID + " | " + analysis.clips[$0].url.lastPathComponent : nil } ?? "BLACK | -"
            lines.append(String(format: "%04d  %@ -> %@ | %@ | %@", n + 1, Timecode.format(Double(s.start) / f),
                                Timecode.format(min(analysis.duration, Double(s.end) / f)), name, s.reason))
        }
        for clip in plan.clips {
            lines += ["", "Clip \(clip.label): \(Timecode.format(clip.window.start)) -> \(Timecode.format(clip.window.end))"]
            for s in clip.shots {
                let name = s.camera.flatMap { analysis.clips.indices.contains($0) ? analysis.clips[$0].cameraID : nil } ?? "BLACK"
                lines.append("  \(Timecode.format(Double(s.start) / f - clip.window.start)) \(name) \(s.reason)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
