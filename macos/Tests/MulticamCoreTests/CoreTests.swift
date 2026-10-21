import AVFoundation
import XCTest
@testable import MulticamCore

/// Kick on every beat, hats off-beat, a breakdown with no kick or bass (as in tests/test_smart.py).
func danceTrack(bpm: Double = 128, seconds: Double = 96, breakdown: ClosedRange<Double> = 32...48, sr: Double = 8000) -> [Float] {
    var rng = SeededRandom(seed: 3)
    func noise() -> Float { Float(rng.unit() * 2 - 1) }
    let n = Int(seconds * sr)
    var x = (0..<n).map { _ in 0.004 * noise() }
    let beat = 60 / bpm
    var k = 0
    while Double(k) * beat < seconds {
        let start = Double(k) * beat
        let i = Int(start * sr)
        let quiet = breakdown.contains(start) && start < breakdown.upperBound
        if !quiet {
            for j in 0..<Int(0.12 * sr) where i + j < n {
                let t = Double(j) / sr
                x[i + j] += Float(0.9 * sin(2 * .pi * 55 * t) * exp(-t * 25))
            }
            if k % 4 == 0 { for j in 0..<Int(0.4 * sr) where i + j < n { x[i + j] += Float(0.4 * sin(2 * .pi * 82 * Double(j) / sr)) } }
        }
        let h = Int((start + beat / 2) * sr)
        for j in 0..<Int(0.03 * sr) where h + j < n { x[h + j] += 0.25 * noise() * Float(exp(-Double(j) / sr * 120)) }
        k += 1
    }
    for i in 0..<n {
        let t = Double(i) / sr
        if breakdown.contains(t) { x[i] += Float(0.15 * sin(2 * .pi * 440 * t)) }
    }
    return x
}

final class MusicTests: XCTestCase {
    func testTempoBeatsAndDrop() {
        let info = MusicAnalysis.analyse(danceTrack())
        XCTAssertEqual(info.bpm ?? 0, 128, accuracy: 1)
        XCTAssertGreaterThan(info.confidence, 0.5)
        let steady = zip(info.beats.dropFirst(), info.beats).filter { abs($0 - $1 - 60 / 128) < 0.03 }.count
        XCTAssertGreaterThan(Double(steady) / Double(info.beats.count - 1), 0.9)
        XCTAssertTrue(info.sections.contains { $0.kind == "breakdown" })
        XCTAssertEqual(info.drops.first ?? 0, 48, accuracy: 2)
    }
}

final class PlannerTests: XCTestCase {
    let fps = 30

    func testNoFlashFramesNoBlackAndBeatSynced() {
        let music = MusicAnalysis.analyse(danceTrack())
        let total = 96 * fps
        let cams = ["A", "B", "C"].map { Coverage(angle: $0, first: 0, last: total) }
        var rhythm = Rhythm(); rhythm.cutScale = 0.5
        let scores = Planner.scores(steps: Planner.steps(total: total, fps: fps), vision: [nil, nil, nil])
        let shots = Planner.plan(cameras: cams, total: total, fps: fps, music: music,
                                 sections: music.sections.filter { $0.kind != "normal" }, activities: [], seed: 7,
                                 mainCamera: "A", rhythm: rhythm, scores: scores)
        XCTAssertEqual(shots.first?.start, 0)
        XCTAssertEqual(shots.last?.end, total)
        XCTAssertTrue(zip(shots, shots.dropFirst()).allSatisfy { $0.end == $1.start })
        XCTAssertTrue(shots.dropLast().allSatisfy { Double($0.end - $0.start) / Double(fps) >= 0.6 })
        XCTAssertFalse(shots.contains { $0.camera == nil })
        let beats = music.beats.map { Int(($0 * Double(fps)).rounded()) }
        let onBeat = shots.dropFirst().filter { s in beats.contains { abs($0 - s.start) <= 1 } }.count
        XCTAssertGreaterThanOrEqual(Double(onBeat) / Double(max(1, shots.count - 1)), 0.8)
    }

    func testHandOverAndBlackOnlyWithoutFootage() {
        let cams = [Coverage(angle: "A", first: 0, last: 900), Coverage(angle: "B", first: 0, last: 1800)]
        let scores = Planner.scores(steps: Planner.steps(total: 3000, fps: fps), vision: [nil, nil])
        let shots = Planner.plan(cameras: cams, total: 3000, fps: fps, music: nil, sections: [], activities: [], seed: 1,
                                 mainCamera: "A", rhythm: Rhythm(), scores: scores)
        XCTAssertTrue(shots.filter { $0.start >= 900 && $0.start < 1800 }.allSatisfy { $0.camera == 1 })
        XCTAssertEqual(shots.filter { $0.camera == nil }.map { [$0.start, $0.end] }, [[1800, 3000]])
    }

    func testPoorPictureIsAvoided() {
        let total = 60 * fps
        let steps = Planner.steps(total: total, fps: fps)
        let cams = [Coverage(angle: "A", first: 0, last: total), Coverage(angle: "B", first: 0, last: total)]
        let bad: [Double?] = (0..<steps).map { $0 >= 40 && $0 < 80 ? 0 : 1 }
        let scores = Planner.scores(steps: steps, vision: [(bad, Array(repeating: 0.5, count: steps)), nil])
        let shots = Planner.plan(cameras: cams, total: total, fps: fps, music: nil, sections: [], activities: [], seed: 2,
                                 mainCamera: "A", rhythm: Rhythm(), scores: scores)
        let inBad = shots.filter { $0.camera == 0 }.map { max(0, min($0.end, 40 * fps) - max($0.start, 20 * fps)) }.reduce(0, +)
        XCTAssertLessThan(Double(inBad), 0.25 * 20 * Double(fps))
    }

    func testClipWindowsAreWholeBarsAndCovered() {
        let music = MusicAnalysis.analyse(danceTrack())
        let total = 96 * fps
        let cams = [Coverage(angle: "A", first: 0, last: 70 * fps)]
        let scores = Planner.scores(steps: Planner.steps(total: total, fps: fps), vision: [nil])
        let windows = Planner.windows(music: music, cameras: cams, total: total, fps: fps, length: 15, scores: scores)
        XCTAssertFalse(windows.isEmpty)
        for w in windows {
            XCTAssertLessThanOrEqual(w.end, 70 + 1e-6)
            XCTAssertEqual(w.end - w.start, 32 * 60 / 128, accuracy: 0.6)
        }
        let best = Planner.choose(windows, count: 2, mode: .best)
        XCTAssertEqual(best.count, 2)
        XCTAssertLessThanOrEqual(best[0].end, best[1].start + 1e-6)
    }
}

final class FormatTests: XCTestCase {
    func testSizes() {
        XCTAssertTrue(Aspect.landscape.size(resolution: 2160) == (3840, 2160))
        XCTAssertTrue(Aspect.portrait.size(resolution: 1080) == (1080, 1920))
        XCTAssertTrue(Aspect.feed.size(resolution: 1080) == (1080, 1350))
        XCTAssertTrue(Aspect.square.size(resolution: 720) == (720, 720))
    }

    func testWebProjectRoundTrip() throws {
        let json = """
        {"cameras":[{"id":"A","label":"Front","clips":[{"path":"/x/a.MOV","framing":{"mode":"fit","center":[0.5,0.5],"zoom":1}}]}],
         "audio":"/x/set.wav","output_dir":"/out","output_name":"multicam_cut.mp4","mode":"vertical","main_camera":"A",
         "main_share":0.6,"seed":7,"fps":25,"cut_scale":0.8,"main_hold":[20,60],"drops":[[10,20]]}
        """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(project.aspect, .portrait)
        XCTAssertEqual(project.outputName, "multicam_cut")
        XCTAssertEqual(project.cameras[0].clips[0].framing.mode, .fit)
        XCTAssertEqual(project.parts.first?.drops, [[10, 20]])
        let again = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(again, project)
    }

    func testCropMatchesEngineMaths() {
        let info = MediaInfo(url: URL(fileURLWithPath: "/x"), duration: 1, hasVideo: true, hasAudio: true,
                             naturalSize: CGSize(width: 1920, height: 1080), orientedSize: CGSize(width: 1920, height: 1080),
                             transform: .identity, frameRate: 30, videoStart: 0, audioStart: 0, isHDR: false)
        let style = LayerStyle(framing: Framing(mode: .crop, center: [0.25, 0.5], zoom: 1, auto: false), focus: nil, info: info)
        let rect = style.cropRect(output: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(rect.height, 1080, accuracy: 0.5)
        XCTAssertEqual(rect.width, 607.5, accuracy: 0.5)
        XCTAssertEqual(rect.minX, 1920 * 0.25 - 607.5 / 2, accuracy: 0.5)
    }
}

final class ClipOptionTests: XCTestCase {
    func info(_ w: Double, _ h: Double) -> MediaInfo {
        MediaInfo(url: URL(fileURLWithPath: "/x"), duration: 1, hasVideo: true, hasAudio: true, naturalSize: CGSize(width: w, height: h),
                  orientedSize: CGSize(width: w, height: h), transform: .identity, frameRate: 30, videoStart: 0, audioStart: 0, isHDR: false)
    }

    func testSmartFramingFitsWideShotsAndCropsCloseMatches() {
        let crop = Framing(mode: .crop, center: [0.3, 0.5], zoom: 1, auto: false)
        XCTAssertEqual(Engine.clipFraming(crop, info: info(1920, 1080), aspect: .portrait, mode: .smart).mode, .fit)
        XCTAssertEqual(Engine.clipFraming(crop, info: info(1080, 1920), aspect: .portrait, mode: .smart).mode, .crop)
        XCTAssertEqual(Engine.clipFraming(crop, info: info(1920, 1080), aspect: .landscape, mode: .smart).mode, .crop)
        XCTAssertEqual(Engine.clipFraming(Framing(mode: .fit), info: info(1920, 1080), aspect: .portrait, mode: .crop).mode, .crop)
        XCTAssertEqual(Engine.clipFraming(crop, info: info(1920, 1080), aspect: .portrait, mode: .same), crop)
    }

    func testSocialLengthsAndPlanIdentity() {
        var project = Project()
        XCTAssertEqual(project.socialLengths, [])
        project.clips = 15
        XCTAssertEqual(project.socialLengths, [15])
        project.clipLengths = [60, 15, 30, 15, 1]
        XCTAssertEqual(project.socialLengths, [15, 30, 60])
        let plan = EditPlan(shots: [], clips: [], sections: [], total: 1, fps: 30, partPath: "/a.wav", clipCount: 2)
        XCTAssertFalse(plan.matches(nil))
    }
}

final class CompositionTests: XCTestCase {
    func testInstructionsAlwaysReachTheCompositionEnd() {
        // 2.1.0 bug: audio cut on a 48 kHz grid ran 1/48000 s past the last video frame (error -11841).
        let a = MulticamInstruction(timeRange: CMTimeRange(start: .zero, end: CMTime(value: 100, timescale: 30)),
                                    trackID: nil, style: nil, look: Look(), totalDuration: 7)
        let b = MulticamInstruction(timeRange: CMTimeRange(start: CMTime(value: 100, timescale: 30), end: CMTime(value: 212, timescale: 30)),
                                    trackID: nil, style: nil, look: Look(), totalDuration: 7)
        let longer = Renderer.covering([a, b], duration: CMTime(value: 339201, timescale: 48000))
        XCTAssertEqual(longer.last?.timeRange.end, CMTime(value: 339201, timescale: 48000))
        let shorter = Renderer.covering([a, b], duration: CMTime(value: 90, timescale: 30))
        XCTAssertEqual(shorter.count, 1)
        XCTAssertEqual(shorter.last?.timeRange.end, CMTime(value: 90, timescale: 30))
    }
}

final class SyncTests: XCTestCase {
    func testCorrelationFindsTemplate() {
        var rng = SeededRandom(seed: 9)
        let reference = (0..<200_000).map { _ in Float(rng.unit() * 2 - 1) }
        let template = reference[123_456..<(123_456 + 16_000)]
        let (position, score) = AudioSync.matchAnchor(reference, template)
        XCTAssertEqual(position * AudioSync.sampleRate, 123_456, accuracy: 0.5)
        XCTAssertGreaterThan(score, 0.99)
    }

    func testSynchroniseRecoversOffset() throws {
        var rng = SeededRandom(seed: 4)
        let sr = AudioSync.sampleRate
        let bounce = (0..<Int(60 * sr)).map { _ in Float(rng.unit() * 2 - 1) }
        // The camera started 7.5 s before the bounce and recorded 40 s of it, with room noise.
        let lead = Int(7.5 * sr)
        var camera = (0..<lead).map { _ in Float(rng.unit() - 0.5) * 0.3 }
        camera += bounce[0..<Int(40 * sr)].map { $0 * 0.6 + Float(rng.unit() - 0.5) * 0.2 }
        let info = MediaInfo(url: URL(fileURLWithPath: "/cam.mov"), duration: Double(camera.count) / sr, hasVideo: true, hasAudio: true,
                             naturalSize: .zero, orientedSize: .zero, transform: .identity, frameRate: 30,
                             videoStart: 0, audioStart: 0, isHDR: false)
        let result = try AudioSync.synchronise(camera: camera, info: info, bounce: bounce, allowDrift: true)
        XCTAssertEqual(result.offset, -7.5, accuracy: 0.002)
        XCTAssertEqual(result.rate, 1, accuracy: 1e-4)
    }
}

/// A small synthetic recording made with FFmpeg: a flat colour picture plus part of the audio.
func makeMovie(_ url: URL, colour: String, audio: URL, from start: Double, seconds: Double) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i", "color=c=\(colour):s=320x180:r=30:d=\(seconds)",
                         "-ss", String(start), "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0", "-c:v", "libx264",
                         "-preset", "ultrafast", "-c:a", "pcm_s16le", "-t", String(seconds), url.path]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 { throw MulticamError("ffmpeg failed") }
}

func ffmpegAvailable() -> Bool {
    ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].contains { FileManager.default.isExecutableFile(atPath: $0) }
}

final class EndToEndTests: XCTestCase {
    func testSyncPlanAndRenderClips() async throws {
        try XCTSkipUnless(ffmpegAvailable(), "Needs FFmpeg to make test recordings")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mcstudio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sr = 16000.0
        let set = danceTrack(seconds: 40, breakdown: 12...20, sr: 8000)
        // Upsample by repetition for a 16 kHz bounce (content only needs to be shared).
        let bounce = set.flatMap { [$0 * 0.5, $0 * 0.5] }
        let bounceURL = folder.appendingPathComponent("set.wav")
        do {  // AVAudioFile finishes the WAV header when it is released
            let file = try AVAudioFile(forWriting: bounceURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr,
                                                                         AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(bounce.count))!
            buffer.frameLength = AVAudioFrameCount(bounce.count)
            for i in 0..<bounce.count { buffer.floatChannelData![0][i] = bounce[i] }
            try file.write(from: buffer)
        }
        // Camera A covers everything; camera B starts 3 s late.
        let a = folder.appendingPathComponent("a.mov"), b = folder.appendingPathComponent("b.mov")
        try makeMovie(a, colour: "red", audio: bounceURL, from: 0, seconds: 40)
        try makeMovie(b, colour: "blue", audio: bounceURL, from: 3, seconds: 37)
        var project = Project()
        project.cameras = [CameraDefinition(id: "A", label: "A", clips: [ClipSource(path: a.path)]),
                           CameraDefinition(id: "B", label: "B", clips: [ClipSource(path: b.path, framing: Framing(mode: .fit))])]
        project.audio = bounceURL.path
        project.outputDir = folder.appendingPathComponent("out").path
        project.resolution = 720; project.clipResolution = 720
        project.clips = 7; project.clipLengths = [7, 10]; project.clipCount = 2
        let engine = Engine(cacheDirectory: folder.appendingPathComponent("cache"), log: { _ in })
        let analysis = try await engine.analyse(project: project, part: project.parts[0], vision: false)
        XCTAssertEqual(analysis.clips.count, 2)
        let syncB = try XCTUnwrap(analysis.clips.first { $0.cameraID == "B" }?.sync)
        XCTAssertEqual(syncB.offset, 3, accuracy: 0.01)
        let plan = try Engine.plan(project: project, analysis: analysis)
        XCTAssertEqual(plan.clips.count, 4)
        XCTAssertTrue(plan.matches(analysis))
        XCTAssertEqual(Set(plan.clips.map(\.length)), [7, 10])
        let outputs = try await engine.render(project: project, analysis: analysis, plan: plan,
                                              folder: URL(fileURLWithPath: project.outputDir)) { _, _ in }
        XCTAssertEqual(outputs.count, 5)
        XCTAssertTrue(outputs.contains { $0.url.path.contains("_clips/10s/") })
        for output in outputs {
            let asset = AVURLAsset(url: output.url)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let size = try await track.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(duration, output.end - output.start, accuracy: 0.1)
            if output.kind == "clip" { XCTAssertEqual(size, CGSize(width: 720, height: 1280)) }
            else { XCTAssertEqual(size, CGSize(width: 1280, height: 720)) }
        }
    }
}
