import Foundation

/// AI mode: turns a plain-language request into the settings a person would set by hand (main camera,
/// pace, forced cameras, drops and breakdowns, no-clip ranges, clip lengths and filters). The engine still
/// makes every cut, so the cuts keep their style. Providers: the Claude Code or Codex command-line tools
/// (signed in with your subscription) or an OpenRouter API key. Mirrors ai.py; keep SYSTEM_PROMPT/SCHEMA identical.
public enum AIGuide {
    public enum Provider: String, CaseIterable, Identifiable, Sendable {
        case claude, codex, openrouter
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .claude: "Claude Code (your subscription)"
            case .codex: "Codex (your subscription)"
            case .openrouter: "OpenRouter (API key)"
            }
        }
    }

    public static let defaultOpenRouterModel = "openrouter/auto"
    public static let timeout: TimeInterval = 300

    public static let systemPrompt = """
You are the assistant editor inside Multicam Studio, an app that cuts DJ sets filmed with several cameras.
The app's editing engine already makes beat-synced cuts, faster in drops and slower in breakdowns. You never
make cuts yourself: you steer the engine by choosing settings, exactly as the DJ would by hand.

You get a JSON summary of the set (audio parts with their duration, tempo, drops and sections; the cameras,
with their shape; the current settings and markers) and a request from the DJ. Return ONLY a JSON object:
- "summary": one or two sentences telling the DJ what you changed and why.
- "main_camera": a camera id to favour, or null to keep it.
- "main_share": share of screen time for the main camera, 0.2 to 0.9, or null.
- "pace": cutting speed, 0.4 (much slower) to 2.5 (much faster), 1 = normal, or null.
- "clip_lengths": social clip lengths in seconds (e.g. [15, 30]), or null.
- "clip_count": social clips per length (0 = as many as fit), or null.
- "clip_mode": "best" (most energetic moments) or "sequence" (whole set in order), or null.
- "clip_filters": "auto", "off" or one look (none, warm, cool, mono, vintage, vivid, noir, silver, sepia, super8, faded), or null.
- "parts": a list with one entry per audio part you change: {"part": its number, "force_cameras": [{"start", "end", "camera"}],
  "no_clips": [[start, end]], "drops": [[start, end]], "breakdowns": [[start, end]]}. Times are seconds within that part.
  Forced cameras override the engine in that range; no_clips keeps social clips out of a range; drops and
  breakdowns replace the detected sections for that part, so only add them when the DJ asks.
Change only what the request needs; use null or empty lists for the rest. Use camera ids exactly as given.
Keep forced ranges to what was asked for: the engine's own choices are usually best.
"""

    public static let schema = #"{"type":"object","additionalProperties":false,"required":["summary","main_camera","main_share","pace","clip_lengths","clip_count","clip_mode","clip_filters","parts"],"properties":{"summary":{"type":"string"},"main_camera":{"type":["string","null"]},"main_share":{"type":["number","null"]},"pace":{"type":["number","null"]},"clip_lengths":{"type":["array","null"],"items":{"type":"number"}},"clip_count":{"type":["integer","null"]},"clip_mode":{"type":["string","null"],"enum":["best","sequence",null]},"clip_filters":{"type":["string","null"]},"parts":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["part","force_cameras","no_clips","drops","breakdowns"],"properties":{"part":{"type":"integer"},"force_cameras":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["start","end","camera"],"properties":{"start":{"type":"number"},"end":{"type":"number"},"camera":{"type":"string"}}}},"no_clips":{"type":"array","items":{"type":"array","items":{"type":"number"}}},"drops":{"type":"array","items":{"type":"array","items":{"type":"number"}}},"breakdowns":{"type":"array","items":{"type":"array","items":{"type":"number"}}}}}}}}"#

    public struct ForcedRange: Hashable, Sendable {
        public var start: Double, end: Double, camera: String
        public init(start: Double, end: Double, camera: String) { self.start = start; self.end = end; self.camera = camera }
    }

    public struct PartGuidance: Hashable, Sendable {
        public var part: Int
        public var forceCameras: [ForcedRange] = []
        public var noClips: [[Double]] = []
        public var drops: [[Double]] = []
        public var breakdowns: [[Double]] = []
        var isEmpty: Bool { forceCameras.isEmpty && noClips.isEmpty && drops.isEmpty && breakdowns.isEmpty }
        public init(part: Int, forceCameras: [ForcedRange] = [], noClips: [[Double]] = [], drops: [[Double]] = [], breakdowns: [[Double]] = []) {
            self.part = part; self.forceCameras = forceCameras; self.noClips = noClips; self.drops = drops; self.breakdowns = breakdowns
        }
    }

    public struct Guidance: Sendable {
        public var summary = "Done."
        public var mainCamera: String?
        public var mainShare: Double?
        public var pace: Double?
        public var clipLengths: [Double]?
        public var clipCount: Int?
        public var clipMode: ClipMode?
        public var clipFilters: String?
        public var parts: [PartGuidance] = []
        public init() {}
    }

    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    // MARK: context

    /// The set summary the AI reads: parts with tempo, drops and sections, cameras with their shape, settings.
    public static func context(project: Project, analyses: [String: PartAnalysis], shapes: [String: String]) -> [String: Any] {
        func r(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        var parts = [[String: Any]]()
        for (i, part) in project.parts.prefix(100).enumerated() {
            var entry: [String: Any] = ["part": i + 1, "name": URL(fileURLWithPath: part.path).deletingPathExtension().lastPathComponent]
            if let analysis = analyses[part.path] {
                entry["duration"] = r(analysis.duration)
                if let bpm = analysis.music.bpm { entry["bpm"] = r(bpm) }
                entry["drops"] = analysis.music.drops.prefix(80).map(r)
                entry["sections"] = analysis.music.sections.prefix(150).map { ["start": r($0.start), "end": r($0.end), "kind": $0.kind] }
            } else {
                entry["note"] = "Not analysed yet"
            }
            entry["marked"] = ["drops": part.drops, "breakdowns": part.breakdowns, "no_clips": part.clipExcludes,
                               "forced": part.shotOverrides.map { ["start": $0.start, "end": $0.end, "camera": $0.cameraID] }]
            parts.append(entry)
        }
        let cameras: [[String: Any]] = project.cameras.map {
            ["id": $0.id, "label": $0.label, "shape": shapes[$0.id] ?? "unknown", "main": $0.id == project.mainCamera]
        }
        let settings: [String: Any] = ["main_camera": project.mainCamera, "main_share": project.mainShare, "cut_scale": project.cutScale,
                                       "clip_lengths": project.socialLengths, "clip_count": project.clipCount,
                                       "clip_mode": project.clipMode.rawValue, "clip_filters": project.clipFilters,
                                       "aspect": project.aspect.rawValue, "clip_aspect": project.clipAspect.rawValue]
        return ["parts": parts, "cameras": cameras, "settings": settings]
    }

    public static func requestText(_ prompt: String, context: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])) ?? Data()
        return "Set summary (JSON):\n\(String(decoding: data, as: UTF8.self))\n\nRequest from the DJ:\n\(prompt.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    // MARK: asking

    public static func ask(_ provider: Provider, prompt: String, context: [String: Any], key: String = "", model: String = "") async throws -> Guidance {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("Tell the AI what you want first.") }
        let text = requestText(prompt, context: context)
        let raw: String
        switch provider {
        case .openrouter: raw = try await openRouter(text, key: key, model: model.isEmpty ? defaultOpenRouterModel : model)
        case .claude, .codex: raw = try await runCLI(provider, text: text, model: model)
        }
        return validate(try parse(raw), context: context)
    }

    /// The tool's path and the login shell's PATH (apps don't inherit the Terminal's PATH).
    public static func findCLI(_ name: String) -> (path: String, environment: [String: String])? {
        var environment = ProcessInfo.processInfo.environment
        let shell = Process(), pipe = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "echo \"$PATH\"; command -v \(name)"]
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        var lines = [String]()
        if (try? shell.run()) != nil {
            lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
            shell.waitUntilExit()
        }
        if let path = lines.first, !path.isEmpty { environment["PATH"] = path }
        if lines.count > 1, FileManager.default.isExecutableFile(atPath: lines[1]) { return (lines[1], environment) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for folder in ["\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = "\(folder)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return (candidate, environment) }
        }
        return nil
    }

    static func runCLI(_ provider: Provider, text: String, model: String) async throws -> String {
        let name = provider == .claude ? "claude" : "codex"
        guard let tool = findCLI(name) else {
            throw Failure("\(provider == .claude ? "Claude Code" : "Codex") isn’t installed. Install it and sign in, or use OpenRouter.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("multicam-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // An empty folder, no tools and no saved session: the AI only reads the summary and answers.
        var arguments: [String]
        let answer = work.appendingPathComponent("answer.json")
        if provider == .claude {
            arguments = ["-p", "--output-format", "json", "--tools", "", "--no-session-persistence",
                         "--json-schema", schema, "--system-prompt", systemPrompt]
            if !model.isEmpty { arguments += ["--model", model] }
            arguments.append(text)
        } else {
            let schemaFile = work.appendingPathComponent("schema.json")
            try schema.write(to: schemaFile, atomically: true, encoding: .utf8)
            arguments = ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
                         "--output-schema", schemaFile.path, "-o", answer.path]
            if !model.isEmpty { arguments += ["-m", model] }
            arguments.append(systemPrompt + "\n\n" + text)
        }
        let (status, output, errors) = try await run(tool.path, arguments, environment: tool.environment, in: work)
        if provider == .claude {
            guard let envelope = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else {
                throw Failure(tail(errors.isEmpty ? output : errors).isEmpty ? "Claude Code gave no answer." : tail(errors.isEmpty ? output : errors))
            }
            if envelope["is_error"] as? Bool == true {
                var message = (envelope["result"] as? String) ?? "Claude Code returned an error."
                if message.lowercased().contains("authenticat") || message.contains("401") { message += " Open Terminal and run \"claude\" to sign in again." }
                throw Failure(message)
            }
            if let structured = envelope["structured_output"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: structured) { return String(decoding: data, as: UTF8.self) }
            return envelope["result"] as? String ?? ""
        }
        guard status == 0, let text = try? String(contentsOf: answer, encoding: .utf8) else {
            var message = tail(errors.isEmpty ? output : errors)
            if message.isEmpty { message = "Codex gave no answer." }
            if message.lowercased().contains("login") || message.lowercased().contains("auth") {
                message += " Open Terminal and run \"codex login\" to sign in."
            } else if message.lowercased().contains("model") {
                message += " Type a model your Codex account supports in the Model box, or change it in ~/.codex/config.toml."
            }
            throw Failure(message)
        }
        return text
    }

    static func run(_ tool: String, _ arguments: [String], environment: [String: String], in folder: URL) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process(), out = Pipe(), err = Pipe()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = folder
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.wait()
                process.waitUntilExit()
                timer.cancel()
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: Failure("The AI took too long to answer. Try again or use a shorter request."))
                    return
                }
                continuation.resume(returning: (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func openRouter(_ text: String, key: String, model: String) async throws -> String {
        guard !key.isEmpty else { throw Failure("Add your OpenRouter API key first.") }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Multicam Studio", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = ["model": model, "response_format": ["type": "json_object"],
                                   "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": text]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure("OpenRouter: \(message)")
        }
        guard let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String else {
            throw Failure("OpenRouter returned no answer.")
        }
        return content
    }

    static func tail(_ text: String) -> String {
        if let regex = try? NSRegularExpression(pattern: #""message"\s*:\s*"([^"]+)""#),
           let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
           let range = Range(match.range(at: 1), in: text) { return String(text[range].prefix(500)) }
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return String(lines.suffix(3).joined(separator: " ").suffix(500))
    }

    // MARK: checking the answer

    /// The first JSON object in the answer (models sometimes wrap it in prose or a code fence).
    public static func parse(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] { return object }
        let chars = Array(trimmed)
        var start = chars.firstIndex(of: "{")
        while let s = start {
            var depth = 0
            for i in s..<chars.count {
                if chars[i] == "{" { depth += 1 } else if chars[i] == "}" {
                    depth -= 1
                    if depth == 0 {
                        if let object = try? JSONSerialization.jsonObject(with: Data(String(chars[s...i]).utf8)) as? [String: Any] { return object }
                        break
                    }
                }
            }
            start = chars[(s + 1)...].firstIndex(of: "{")
        }
        throw Failure("The AI’s answer wasn’t in the expected format. Try again.")
    }

    static func number(_ value: Any?, _ low: Double, _ high: Double) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let x = n.doubleValue
        return x.isFinite ? min(high, max(low, x)) : nil
    }

    static func ranges(_ value: Any?, _ duration: Double) -> [[Double]] {
        let pairs = (value as? [Any]) ?? []
        var out = [[Double]]()
        for pair in pairs {
            guard let p = pair as? [Any], p.count == 2, let a = number(p[0], 0, duration), let b = number(p[1], 0, duration), b - a >= 0.5 else { continue }
            out.append([(a * 1000).rounded() / 1000, (b * 1000).rounded() / 1000])
        }
        return Array(out.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }.prefix(200))
    }

    /// Keep only well-formed values inside the limits the engine accepts (same rules as ai.validate).
    public static func validate(_ raw: [String: Any], context: [String: Any]) -> Guidance {
        let cameras = Set(((context["cameras"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String })
        let parts = (context["parts"] as? [[String: Any]]) ?? []
        var g = Guidance()
        g.summary = String(((raw["summary"] as? String) ?? "Done.").trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        if let camera = raw["main_camera"] as? String, cameras.contains(camera) { g.mainCamera = camera }
        if let share = number(raw["main_share"], 0.2, 0.9) { g.mainShare = (share * 100).rounded() / 100 }
        if let pace = number(raw["pace"], 0.4, 2.5) { g.pace = (pace * 100).rounded() / 100 }
        if let lengths = raw["clip_lengths"] as? [Any] {
            let clean = Array(Set(lengths.compactMap { number($0, 3, 180) }.map { $0.rounded() })).sorted().prefix(6)
            if !clean.isEmpty { g.clipLengths = Array(clean) }
        }
        if let count = number(raw["clip_count"], 0, 50) { g.clipCount = Int(count) }
        if let mode = raw["clip_mode"] as? String { g.clipMode = ClipMode(rawValue: mode) }
        if let filters = raw["clip_filters"] as? String, filters == "auto" || filters == "off" || Look.Style(rawValue: filters) != nil {
            g.clipFilters = filters
        }
        var byPart = [Int: PartGuidance]()
        for item in (raw["parts"] as? [Any]) ?? [] {
            guard let item = item as? [String: Any], let n = item["part"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue == n.doubleValue.rounded() else { continue }
            let index = n.intValue
            guard (1...parts.count).contains(index) else { continue }
            let duration = (parts[index - 1]["duration"] as? Double) ?? 86_400
            var entry = byPart[index] ?? PartGuidance(part: index)
            for force in (item["force_cameras"] as? [Any]) ?? [] {
                guard let force = force as? [String: Any], let camera = force["camera"] as? String, cameras.contains(camera),
                      let span = ranges([[force["start"] as Any, force["end"] as Any]], duration).first else { continue }
                entry.forceCameras.append(ForcedRange(start: span[0], end: span[1], camera: camera))
            }
            entry.noClips += ranges(item["no_clips"], duration)
            entry.drops += ranges(item["drops"], duration)
            entry.breakdowns += ranges(item["breakdowns"], duration)
            byPart[index] = entry
        }
        g.parts = byPart.values.filter { !$0.isEmpty }.sorted { $0.part < $1.part }
        return g
    }

    /// Short lines listing what will change.
    public static func describe(_ g: Guidance) -> [String] {
        var lines = [String]()
        if let c = g.mainCamera { lines.append("Main camera: \(c)") }
        if let s = g.mainShare { lines.append("Main camera screen time: \(Int((s * 100).rounded()))%") }
        if let p = g.pace { lines.append("Pace: \(p)×") }
        if let l = g.clipLengths { lines.append("Clip lengths: " + l.map { "\(Int($0)) s" }.joined(separator: ", ")) }
        if let c = g.clipCount { lines.append("Clips per length: \(c == 0 ? "as many as fit" : String(c))") }
        if let m = g.clipMode { lines.append("Clips: " + (m == .best ? "best moments" : "whole set in order")) }
        if let f = g.clipFilters { lines.append("Filters: \(f)") }
        for part in g.parts {
            var bits = [String]()
            if !part.forceCameras.isEmpty { bits.append("\(part.forceCameras.count) forced camera range(s)") }
            if !part.noClips.isEmpty { bits.append("\(part.noClips.count) no-clip range(s)") }
            if !part.drops.isEmpty { bits.append("\(part.drops.count) drop(s)") }
            if !part.breakdowns.isEmpty { bits.append("\(part.breakdowns.count) breakdown(s)") }
            lines.append("Part \(part.part): " + bits.joined(separator: ", "))
        }
        return lines
    }

    /// Apply guidance to a project (forced ranges replace overlapping ones; markers are added).
    public static func apply(_ g: Guidance, to project: inout Project) {
        if let c = g.mainCamera { project.mainCamera = c }
        if let s = g.mainShare { project.mainShare = s }
        if let p = g.pace { project.cutScale = 1 / p }
        if let l = g.clipLengths { project.clipLengths = l; project.clips = l.min() ?? project.clips }
        if let c = g.clipCount { project.clipCount = c }
        if let m = g.clipMode { project.clipMode = m }
        if let f = g.clipFilters { project.clipFilters = f }
        var parts = project.parts
        for pg in g.parts where parts.indices.contains(pg.part - 1) {
            var part = parts[pg.part - 1]
            part.shotOverrides.removeAll { o in pg.forceCameras.contains { $0.start < o.end && o.start < $0.end } }
            part.shotOverrides += pg.forceCameras.map { ShotOverride(start: $0.start, end: $0.end, cameraID: $0.camera) }
            part.shotOverrides.sort { $0.start < $1.start }
            part.drops += pg.drops
            part.breakdowns += pg.breakdowns
            part.clipExcludes += pg.noClips
            parts[pg.part - 1] = part
        }
        if project.audioParts.isEmpty, let only = parts.first {
            project.overrides = only.overrides; project.shotOverrides = only.shotOverrides
            project.drops = only.drops; project.breakdowns = only.breakdowns; project.clipExcludes = only.clipExcludes
        } else if !project.audioParts.isEmpty {
            project.audioParts = parts
        }
    }
}
