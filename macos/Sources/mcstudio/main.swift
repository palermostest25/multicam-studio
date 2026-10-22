import AVFoundation
import Foundation
import MulticamCore

// Command-line front end for the native engine.
//
//   mcstudio render PROJECT.json [--plan-only] [--range START,END] [--no-vision]
//   mcstudio music AUDIO
//   mcstudio vision VIDEO
//
// Projects are the JSON files saved by the app or the browser version.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("Usage: mcstudio render PROJECT.json [--plan-only] [--range START,END] [--no-vision] | music AUDIO | vision VIDEO")
}

func run() async throws {
    switch command {
    case "music":
        guard arguments.count == 2 else { fail("Usage: mcstudio music AUDIO") }
        let started = Date()
        let info = try await MusicAnalysis.analyse(url: URL(fileURLWithPath: arguments[1]))
        print(String(format: "%.1f BPM, confidence %.3f, %d beats, %d bars, %.1f s", info.bpm ?? 0, info.confidence,
                     info.beats.count, info.downbeats.count, Date().timeIntervalSince(started)))
        print("drops:", info.drops)
        print("sections:", info.sections.map { "\($0.kind.prefix(1)) \(Int($0.start))-\(Int($0.end))" }.joined(separator: ", "))
    case "vision":
        guard arguments.count == 2 else { fail("Usage: mcstudio vision VIDEO") }
        let started = Date()
        let scores = try await VisionAnalysis.analyse(URL(fileURLWithPath: arguments[1]), cacheDirectory: nil)
        let poor = scores.usable.filter { $0 < 0.5 }.count
        print(String(format: "%d samples, %d poor, focus %@, %.1f s", scores.times.count, poor,
                     scores.focus.description, Date().timeIntervalSince(started)))
    case "render":
        guard arguments.count >= 2 else { fail("Usage: mcstudio render PROJECT.json") }
        var project = try Project.load(URL(fileURLWithPath: arguments[1]))
        let planOnly = arguments.contains("--plan-only")
        let vision = !arguments.contains("--no-vision")
        var range: (Double, Double)?
        if let i = arguments.firstIndex(of: "--range"), i + 1 < arguments.count {
            let parts = arguments[i + 1].split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 { range = (parts[0], parts[1]) }
        }
        if project.outputDir.isEmpty { project.outputDir = FileManager.default.currentDirectoryPath }
        let engine = Engine(log: { print($0) }, status: { _, _ in })
        let parts = project.parts
        guard !parts.isEmpty else { fail("The project has no audio.") }
        for (index, part) in parts.enumerated() {
            print("== Audio \(index + 1)/\(parts.count): \(URL(fileURLWithPath: part.path).lastPathComponent)")
            let started = Date()
            let analysis = try await engine.analyse(project: project, part: part, vision: vision)
            print(String(format: "Analysis took %.1f s", Date().timeIntervalSince(started)))
            var plan = try Engine.plan(project: project, analysis: analysis)
            let folder = Engine.outputFolder(project: project, partIndex: index + 1, partCount: parts.count, part: part)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let list = Engine.cutList(project: project, analysis: analysis, plan: plan)
            try list.write(to: folder.appendingPathComponent("cut_list.txt"), atomically: true, encoding: .utf8)
            let durations = plan.shots.filter { $0.camera != nil }.map { Double($0.end - $0.start) / Double(plan.fps) }
            print(String(format: "Plan: %d shots, %.1f s average, shortest %.2f s, %d clips",
                         plan.shots.count, durations.reduce(0, +) / Double(max(1, durations.count)),
                         durations.min() ?? 0, plan.clips.count))
            if arguments.contains("--check-preview") {
                let spec = OutputSpec(width: 960, height: 540, fps: plan.fps, codec: .h264)
                let edit = try await Renderer.prepare(shots: plan.shots, clips: analysis.clips, bounce: URL(fileURLWithPath: part.path),
                                                      window: 0..<plan.total, spec: spec)
                let item = edit.playerItem()
                let player = AVPlayer(playerItem: item)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
                item.add(output)
                player.play()
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    if item.status != .unknown { break }
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                print("player item status \(item.status.rawValue) error \(String(describing: item.error)) time \(player.currentTime().seconds) frames \(output.hasNewPixelBuffer(forItemTime: item.currentTime()))")
                if let log = item.errorLog() { print(log.events.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" }) }
                continue
            }
            if planOnly { continue }
            if let (a, b) = range {
                let f = Double(plan.fps)
                let lo = Int((a * f).rounded()), hi = min(plan.total, Int((b * f).rounded()))
                plan.shots = plan.shots.filter { $0.end > lo && $0.start < hi }
                    .map { Shot(start: max($0.start, lo), end: min($0.end, hi), camera: $0.camera, reason: $0.reason) }
                // Render the range as a "full" output covering just that window.
                let spec = project.aspect.size(resolution: project.resolution)
                let output = OutputSpec(width: spec.width, height: spec.height, fps: plan.fps, codec: project.codec, crf: project.crf, look: project.look)
                let edit = try await Renderer.prepare(shots: plan.shots, clips: analysis.clips, bounce: URL(fileURLWithPath: part.path),
                                                      window: lo..<hi, spec: output)
                let url = folder.appendingPathComponent("\(Engine.baseName(project))_\(Int(a))-\(Int(b)).\(project.codec.fileExtension)")
                let t0 = Date()
                try await Renderer.export(edit, to: url, spec: output) { _ in }
                let seconds = Date().timeIntervalSince(t0)
                print(String(format: "Rendered %@ in %.1f s (%.1f× real time)", url.lastPathComponent, seconds, (b - a) / seconds))
                continue
            }
            let social = Engine.socialFolder(project: project, partIndex: index + 1, partCount: parts.count, part: part)
            let outputs = try await engine.render(project: project, analysis: analysis, plan: plan, folder: folder,
                                                  clipFolder: social,
                                                  alternativesFolders: Engine.alternativeFolders(project: project, partIndex: index + 1, partCount: parts.count, part: part)) { title, fraction in
                FileHandle.standardError.write(String(format: "\r%@ %3.0f%%", title, fraction * 100).data(using: .utf8)!)
            }
            print("")
            for output in outputs { print("Wrote \(output.url.path)") }
        }
    default:
        fail("Unknown command \(command)")
    }
}

// Keep the main run loop free: AVFoundation playback and some callbacks need it.
Task {
    do { try await run() } catch { fail("ERROR: \(error.localizedDescription)\n\(error)") }
    exit(0)
}
RunLoop.main.run()
