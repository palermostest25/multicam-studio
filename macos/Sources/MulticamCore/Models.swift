import Foundation

// Project files are the same JSON the web/Docker version saves ("Save project"),
// so a project moves between the native app, the browser UI and the CLI engine.

public struct Framing: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case crop   // fill the frame with a fixed crop
        case fit    // whole picture over a blurred copy of itself (no black bars)
        case pad    // whole picture with black bars
    }
    public var mode: Mode = .crop
    public var center: [Double] = [0.5, 0.5]
    public var zoom: Double = 1
    public var auto: Bool = true

    public init(mode: Mode = .crop, center: [Double] = [0.5, 0.5], zoom: Double = 1, auto: Bool = true) {
        self.mode = mode; self.center = center; self.zoom = zoom; self.auto = auto
    }

    enum CodingKeys: String, CodingKey { case mode, center, zoom, auto }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .fit
        center = (try? c.decode([Double].self, forKey: .center)) ?? [0.5, 0.5]
        if center.count != 2 { center = [0.5, 0.5] }
        zoom = min(8, max(1, (try? c.decode(Double.self, forKey: .zoom)) ?? 1))
        auto = (try? c.decode(Bool.self, forKey: .auto)) ?? false
    }
    public var x: Double { center[0] }
    public var y: Double { center[1] }
}

public struct ClipSource: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var framing: Framing = Framing()
    public init(path: String, framing: Framing = Framing()) { self.path = path; self.framing = framing }
    public var url: URL { URL(fileURLWithPath: path) }
}

public struct CameraDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var clips: [ClipSource]
    public init(id: String, label: String, clips: [ClipSource]) { self.id = id; self.label = label; self.clips = clips }
    enum CodingKeys: String, CodingKey { case id, label, clips }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = (try? c.decode(String.self, forKey: .label)) ?? id
        clips = (try? c.decode([ClipSource].self, forKey: .clips)) ?? []
    }
}

public struct SyncOverride: Codable, Hashable, Sendable {
    public var path: String
    public var offset: Double?
    public var driftPPM: Double?
    public init(path: String, offset: Double?, driftPPM: Double?) { self.path = path; self.offset = offset; self.driftPPM = driftPPM }
    enum CodingKeys: String, CodingKey { case path, offset; case driftPPM = "drift_ppm" }
}

public struct ShotOverride: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var cameraID: String
    public var sourcePath: String?
    public init(start: Double, end: Double, cameraID: String, sourcePath: String? = nil) {
        self.start = start; self.end = end; self.cameraID = cameraID; self.sourcePath = sourcePath
    }
    enum CodingKeys: String, CodingKey { case start, end; case cameraID = "camera_id"; case sourcePath = "source_path" }
}

/// One audio excerpt and the timing choices that belong to it (zero-based on its own timeline).
public struct AudioPart: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var overrides: [SyncOverride] = []
    public var shotOverrides: [ShotOverride] = []
    public var drops: [[Double]] = []
    public var breakdowns: [[Double]] = []
    public var activities: [Double] = []
    public init(path: String) { self.path = path }
    enum CodingKeys: String, CodingKey {
        case path, overrides, drops, breakdowns, activities
        case shotOverrides = "shot_overrides"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        overrides = (try? c.decode([SyncOverride].self, forKey: .overrides)) ?? []
        shotOverrides = (try? c.decode([ShotOverride].self, forKey: .shotOverrides)) ?? []
        drops = (try? c.decode([[Double]].self, forKey: .drops)) ?? []
        breakdowns = (try? c.decode([[Double]].self, forKey: .breakdowns)) ?? []
        activities = (try? c.decode([Double].self, forKey: .activities)) ?? []
    }
}

public enum Aspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape = "16:9", portrait = "9:16", square = "1:1", feed = "4:5"
    public var id: String { rawValue }
    public var ratio: (Int, Int) {
        switch self { case .landscape: (16, 9); case .portrait: (9, 16); case .square: (1, 1); case .feed: (4, 5) }
    }
    public var title: String {
        switch self {
        case .landscape: "16:9 Landscape (YouTube)"
        case .portrait: "9:16 Vertical (Reels, Shorts, TikTok)"
        case .square: "1:1 Square"
        case .feed: "4:5 Portrait (Instagram feed)"
        }
    }
    public func size(resolution: Int) -> (width: Int, height: Int) {
        let (w, h) = ratio
        if w >= h { return (Int((Double(resolution) * Double(w) / Double(h) / 2).rounded()) * 2, resolution) }
        return (resolution, Int((Double(resolution) * Double(h) / Double(w) / 2).rounded()) * 2)
    }
}

public enum VideoCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264, hevc, prores
    public var id: String { rawValue }
    public var title: String {
        switch self { case .h264: "H.264 (plays everywhere)"; case .hevc: "HEVC / H.265 (smaller files)"; case .prores: "ProRes 422 (for further editing)" }
    }
    public var fileExtension: String { self == .prores ? "mov" : "mp4" }
}

/// How recordings are framed in short clips. Cropping wide footage to 9:16 often cuts off
/// the DJ, so "smart" fits wide shots over a blurred fill and only crops near-matching shapes.
/// Where a short clip stops. The length is a guide either way: clips are whole bars.
public enum ClipEnding: String, Codable, Sendable {
    case beat, bar
}

/// Editing engine. Engine 1 is frozen exactly as shipped in 2.1.3; changes go into Engine 2.
public enum EngineVersion: Int, Codable, CaseIterable, Identifiable, Sendable {
    case one = 1, two = 2
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .one: "Engine 1 (clips stop at the bar line)"
        case .two: "Engine 2 (clips land on the beat)"
        }
    }
    public var clipEnding: ClipEnding { self == .one ? .bar : .beat }
}

public enum ClipFraming: String, Codable, CaseIterable, Identifiable, Sendable {
    case smart, fit, crop, same
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .smart: "Smart (fit wide shots, crop close matches)"
        case .fit: "Fit whole picture · blurred background"
        case .crop: "Crop to fill the frame"
        case .same: "Same as the full edit"
        }
    }
}

public enum ClipMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case best, sequence
    public var id: String { rawValue }
    public var title: String { self == .best ? "Best moments" : "Whole set, in order" }
}

public struct Project: Codable, Hashable, Sendable {
    public var version = 2
    public var cameras: [CameraDefinition] = []
    public var audio: String = ""
    public var audioParts: [AudioPart] = []
    public var outputDir: String = ""
    public var outputName: String = ""
    public var mainCamera: String = "A"
    public var mainShare: Double = 0.7
    public var seed: Int = 42
    public var fps: Int = 30
    public var cutScale: Double = 1
    public var mainHold: [Double] = [20, 60]
    public var cutawayHold: [Double] = [4, 12]
    public var dropHold: [Double] = [3, 6]
    public var breakdownHold: [Double] = [15, 30]
    public var autoSections = true
    public var drift = true
    public var overwrite = false
    public var drops: [[Double]] = []
    public var breakdowns: [[Double]] = []
    public var activities: [Double] = []
    public var overrides: [SyncOverride] = []
    public var shotOverrides: [ShotOverride] = []
    // 2.0 output and planning settings
    public var aspect: Aspect = .landscape
    public var resolution: Int = 2160
    public var codec: VideoCodec = .h264
    public var crf: Int = 18
    public var planner = "smart"
    public var vision = "auto"
    public var fullEdit = true
    public var clips: Double = 0
    public var clipLengths: [Double] = []
    public var clipFraming: ClipFraming = .smart
    public var engine: EngineVersion = .two
    public var clipCount: Int = 5
    public var clipMode: ClipMode = .best
    public var clipAspect: Aspect = .portrait
    public var clipResolution: Int = 1080
    public var clipFade: Double = 0
    public var look = Look()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case version, cameras, audio, seed, fps, drift, overwrite, drops, breakdowns, activities, overrides
        case audioParts = "audio_parts", outputDir = "output_dir", outputName = "output_name"
        case mainCamera = "main_camera", mainShare = "main_share", cutScale = "cut_scale"
        case mainHold = "main_hold", cutawayHold = "cutaway_hold", dropHold = "drop_hold"
        case breakdownHold = "breakdown_hold", autoSections = "auto_sections", shotOverrides = "shot_overrides"
        case aspect, resolution, codec, crf, planner, vision, clips, look
        case fullEdit = "full_edit", clipCount = "clip_count", clipMode = "clip_mode"
        case clipAspect = "clip_aspect", clipResolution = "clip_resolution", clipFade = "clip_fade"
        case clipLengths = "clip_lengths", clipFraming = "clip_framing", engine
        case mode, clipsOnly = "clips_only"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: key)) ?? fallback }
        version = value(.version, 2)
        cameras = value(.cameras, [])
        audio = value(.audio, "")
        audioParts = value(.audioParts, [])
        outputDir = value(.outputDir, "")
        outputName = value(.outputName, "")
        mainCamera = value(.mainCamera, cameras.first?.id ?? "A")
        mainShare = value(.mainShare, 0.7)
        seed = value(.seed, 42)
        fps = value(.fps, 30)
        cutScale = value(.cutScale, 1)
        mainHold = value(.mainHold, [20, 60])
        cutawayHold = value(.cutawayHold, [4, 12])
        dropHold = value(.dropHold, [3, 6])
        breakdownHold = value(.breakdownHold, [15, 30])
        autoSections = value(.autoSections, true)
        drift = value(.drift, true)
        overwrite = value(.overwrite, false)
        drops = value(.drops, [])
        breakdowns = value(.breakdowns, [])
        activities = value(.activities, [])
        overrides = value(.overrides, [])
        shotOverrides = value(.shotOverrides, [])
        let legacyMode: String = value(.mode, "horizontal")
        aspect = value(.aspect, legacyMode == "vertical" ? .portrait : .landscape)
        resolution = value(.resolution, 2160)
        codec = value(.codec, .h264)
        crf = value(.crf, 18)
        planner = value(.planner, "smart")
        vision = value(.vision, "auto")
        clips = value(.clips, 0)
        fullEdit = !value(.clipsOnly, false) && value(.fullEdit, true)
        clipCount = value(.clipCount, 5)
        clipLengths = value(.clipLengths, [])
        clipFraming = value(.clipFraming, .smart)
        engine = value(.engine, .two)
        clipMode = value(.clipMode, .best)
        clipAspect = value(.clipAspect, .portrait)
        clipResolution = value(.clipResolution, 1080)
        clipFade = value(.clipFade, 0)
        look = value(.look, Look())
        if outputName.lowercased().hasSuffix(".mp4") || outputName.lowercased().hasSuffix(".mov") {
            outputName = String(outputName.dropLast(4))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(cameras, forKey: .cameras)
        try c.encode(audio, forKey: .audio)
        try c.encode(audioParts, forKey: .audioParts)
        try c.encode(outputDir, forKey: .outputDir)
        try c.encode(outputName, forKey: .outputName)
        try c.encode(aspect.ratio.1 > aspect.ratio.0 ? "vertical" : "horizontal", forKey: .mode)
        try c.encode(mainCamera, forKey: .mainCamera)
        try c.encode(mainShare, forKey: .mainShare)
        try c.encode(seed, forKey: .seed)
        try c.encode(fps, forKey: .fps)
        try c.encode(cutScale, forKey: .cutScale)
        try c.encode(mainHold, forKey: .mainHold)
        try c.encode(cutawayHold, forKey: .cutawayHold)
        try c.encode(dropHold, forKey: .dropHold)
        try c.encode(breakdownHold, forKey: .breakdownHold)
        try c.encode(autoSections, forKey: .autoSections)
        try c.encode(drift, forKey: .drift)
        try c.encode(overwrite, forKey: .overwrite)
        try c.encode(drops, forKey: .drops)
        try c.encode(breakdowns, forKey: .breakdowns)
        try c.encode(activities, forKey: .activities)
        try c.encode(overrides, forKey: .overrides)
        try c.encode(shotOverrides, forKey: .shotOverrides)
        try c.encode(aspect, forKey: .aspect)
        try c.encode(resolution, forKey: .resolution)
        try c.encode(codec, forKey: .codec)
        try c.encode(crf, forKey: .crf)
        try c.encode(planner, forKey: .planner)
        try c.encode(vision, forKey: .vision)
        try c.encode(fullEdit, forKey: .fullEdit)
        try c.encode(!fullEdit && clips > 0, forKey: .clipsOnly)
        try c.encode(clips, forKey: .clips)
        try c.encode(clipCount, forKey: .clipCount)
        try c.encode(clipLengths, forKey: .clipLengths)
        try c.encode(clipFraming, forKey: .clipFraming)
        try c.encode(engine, forKey: .engine)
        try c.encode(clipMode, forKey: .clipMode)
        try c.encode(clipAspect, forKey: .clipAspect)
        try c.encode(clipResolution, forKey: .clipResolution)
        try c.encode(clipFade, forKey: .clipFade)
        try c.encode(look, forKey: .look)
    }

    /// Short-clip lengths to export (each gets its own folder). Empty when clips are off.
    public var socialLengths: [Double] {
        guard clips > 0 else { return [] }
        let lengths = clipLengths.isEmpty ? [clips] : clipLengths
        return Array(Set(lengths.filter { $0 >= 3 && $0 <= 600 })).sorted()
    }

    /// Every excerpt to export: the audio_parts list, or the single bounce.
    public var parts: [AudioPart] {
        if !audioParts.isEmpty { return audioParts }
        guard !audio.isEmpty else { return [] }
        var part = AudioPart(path: audio)
        part.overrides = overrides; part.shotOverrides = shotOverrides
        part.drops = drops; part.breakdowns = breakdowns; part.activities = activities
        return part.path.isEmpty ? [] : [part]
    }

    public static func load(_ url: URL) throws -> Project {
        try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
    }

    public func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Optional finishing look, applied while rendering (no second encode).
public struct Look: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, warm, cool, mono, vintage, vivid
        public var id: String { rawValue }
    }
    public var style: Style = .none
    public var brightness: Double = 0     // -0.3...0.3
    public var contrast: Double = 1       // 0.5...2
    public var saturation: Double = 1     // 0...2
    public var vignette = false
    public var fadeIn: Double = 0         // seconds, picture and sound
    public var fadeOut: Double = 0
    public init() {}
    enum CodingKeys: String, CodingKey { case style, brightness, contrast, saturation, vignette; case fadeIn = "fade_in", fadeOut = "fade_out" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decode(Style.self, forKey: .style)) ?? .none
        brightness = (try? c.decode(Double.self, forKey: .brightness)) ?? 0
        contrast = (try? c.decode(Double.self, forKey: .contrast)) ?? 1
        saturation = (try? c.decode(Double.self, forKey: .saturation)) ?? 1
        vignette = (try? c.decode(Bool.self, forKey: .vignette)) ?? false
        fadeIn = (try? c.decode(Double.self, forKey: .fadeIn)) ?? 0
        fadeOut = (try? c.decode(Double.self, forKey: .fadeOut)) ?? 0
    }
    public var isNeutral: Bool { style == .none && brightness == 0 && contrast == 1 && saturation == 1 && !vignette }
}

public struct MulticamError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
