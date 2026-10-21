import AVFoundation
import Foundation
import VideoToolbox

/// A camera recording with its sync, framing and place on the output frame grid.
public struct SyncedClip: Sendable {
    public var cameraID: String
    public var label: String
    public var url: URL
    public var info: MediaInfo
    public var framing: Framing
    public var sync: SyncResult
    public var focus: [Double]?
    public var coverage: Coverage

    public init(cameraID: String, label: String, url: URL, info: MediaInfo, framing: Framing, sync: SyncResult,
                focus: [Double]?, coverage: Coverage) {
        self.cameraID = cameraID; self.label = label; self.url = url; self.info = info; self.framing = framing
        self.sync = sync; self.focus = focus; self.coverage = coverage
    }
}

public struct OutputSpec: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var codec: VideoCodec
    public var crf: Int
    public var look: Look
    public init(width: Int, height: Int, fps: Int, codec: VideoCodec, crf: Int = 18, look: Look = Look()) {
        self.width = width; self.height = height; self.fps = fps; self.codec = codec; self.crf = crf; self.look = look
    }
    /// Bitrate equivalent to the FFmpeg engine's CRF mapping for busy, dark club footage.
    public var bitrate: Int {
        let bpp = 0.15 * pow(2, Double(18 - crf) / 6) * (codec == .hevc ? 0.6 : 1)
        return Int(min(200e6, max(1e6, bpp * Double(width * height * fps))))
    }
}

public struct PreparedEdit {
    public let composition: AVMutableComposition
    public let videoComposition: AVMutableVideoComposition
    public let audioMix: AVMutableAudioMix?
    public let duration: Double
    let sources: [AVURLAsset]

    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

public enum Renderer {
    static let debug = ProcessInfo.processInfo.environment["MCSTUDIO_DEBUG"] != nil
    static func trace(_ message: @autoclosure () -> String) {
        if debug { FileHandle.standardError.write(("[render] " + message() + "\n").data(using: .utf8)!) }
    }

    /// Build a composition for frames [window) of the bounce timeline. No pixels are processed here.
    public static func prepare(shots: [Shot], clips: [SyncedClip], bounce: URL, window: Range<Int>, spec: OutputSpec,
                               audioFade: Double = 0, declick: Double = 0) async throws -> PreparedEdit {
        let composition = AVMutableComposition()
        let fps = Int32(spec.fps)
        func frameTime(_ frame: Int) -> CMTime { CMTime(value: CMTimeValue(frame - window.lowerBound), timescale: fps) }
        var tracks = [Int: (AVMutableCompositionTrack, AVAssetTrack)]()
        var assets = [AVURLAsset]()   // tracks hold their asset weakly; keep them alive
        var instructions = [MulticamInstruction]()
        let total = Double(window.count) / Double(spec.fps)
        for shot in shots {
            let start = max(shot.start, window.lowerBound), end = min(shot.end, window.upperBound)
            guard end > start else { continue }
            let range = CMTimeRange(start: frameTime(start), end: frameTime(end))
            guard let index = shot.camera else {
                instructions.append(MulticamInstruction(timeRange: range, trackID: nil, style: nil, look: spec.look, totalDuration: total))
                continue
            }
            let clip = clips[index]
            if tracks[index] == nil {
                let asset = AVURLAsset(url: clip.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                assets.append(asset)
                guard let source = try await asset.loadTracks(withMediaType: .video).first,
                      let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MulticamError("Cannot read the video in \(clip.url.lastPathComponent).")
                }
                tracks[index] = (track, source)
            }
            let (track, source) = tracks[index]!
            let sourceRange = try await source.load(.timeRange)
            // bounce_time = offset + rate * camera_time; camera time counts from the first video frame.
            let t0 = Double(start) / Double(spec.fps), t1 = Double(end) / Double(spec.fps)
            let s0 = max(0, (t0 - clip.sync.offset) / clip.sync.rate) + clip.info.videoStart
            var s1 = (t1 - clip.sync.offset) / clip.sync.rate + clip.info.videoStart
            s1 = min(s1, sourceRange.end.seconds)
            guard s1 > s0 else {
                instructions.append(MulticamInstruction(timeRange: range, trackID: nil, style: nil, look: spec.look, totalDuration: total))
                continue
            }
            let sourceTime = CMTimeRange(start: CMTime(seconds: s0, preferredTimescale: 1_000_000),
                                         end: CMTime(seconds: s1, preferredTimescale: 1_000_000))
            trace("insert \(clip.cameraID) src \(s0)-\(s1) at \(range.start.seconds) dur \(range.duration.seconds) track \(sourceRange.start.seconds)-\(sourceRange.end.seconds)")
            try track.insertTimeRange(sourceTime, of: source, at: range.start)
            // Map the inserted source span exactly onto the output frames (also corrects clock drift).
            track.scaleTimeRange(CMTimeRange(start: range.start, duration: sourceTime.duration), toDuration: range.duration)
            let style = LayerStyle(framing: clip.framing, focus: clip.focus, info: clip.info)
            instructions.append(MulticamInstruction(timeRange: range, trackID: track.trackID, style: style,
                                                    look: spec.look, totalDuration: total))
        }
        guard !instructions.isEmpty else { throw MulticamError("Nothing to render in this range.") }
        // Audio: the bounce only, trimmed to the window.
        let audioAsset = AVURLAsset(url: bounce, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        assets.append(audioAsset)
        var mix: AVMutableAudioMix?
        if let audio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = try await audio.load(.timeRange)
            let a = CMTime(seconds: Double(window.lowerBound) / Double(spec.fps), preferredTimescale: 48000)
            let b = CMTimeMinimum(CMTime(seconds: Double(window.upperBound) / Double(spec.fps), preferredTimescale: 48000), audioRange.end)
            try track.insertTimeRange(CMTimeRange(start: a, end: b), of: audio, at: .zero)
            let length = (b - a).seconds
            let fadeIn = max(declick, spec.look.fadeIn, audioFade), fadeOut = max(declick, spec.look.fadeOut, audioFade)
            if fadeIn > 0 || fadeOut > 0 {
                let parameters = AVMutableAudioMixInputParameters(track: track)
                if fadeIn > 0 {
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                             timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: min(fadeIn, length / 3), preferredTimescale: 48000)))
                }
                if fadeOut > 0 {
                    let d = min(fadeOut, length / 3)
                    parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                             timeRange: CMTimeRange(start: CMTime(seconds: length - d, preferredTimescale: 48000),
                                                                    duration: CMTime(seconds: d, preferredTimescale: 48000)))
                }
                mix = AVMutableAudioMix()
                mix!.inputParameters = [parameters]
            }
        }
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = MulticamCompositor.self
        video.frameDuration = CMTime(value: 1, timescale: fps)
        video.renderSize = CGSize(width: spec.width, height: spec.height)
        video.instructions = instructions
        video.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        video.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        video.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return PreparedEdit(composition: composition, videoComposition: video, audioMix: mix, duration: total, sources: assets)
    }

    /// Encode a prepared edit with the hardware encoder. The old file is only replaced on success.
    public static func export(_ edit: PreparedEdit, to url: URL, spec: OutputSpec,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let reader = try AVAssetReader(asset: edit.composition)
        let videoTracks = edit.composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.videoComposition = edit.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        let audioTracks = edit.composition.tracks(withMediaType: .audio)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = edit.audioMix
            output.alwaysCopiesSampleData = false
            reader.add(output)
            audioOutput = output
        }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: spec.codec == .prores || url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(spec))
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let settings: [String: Any] = spec.codec == .prores
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                   AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 320_000]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }
        trace("starting reader/writer")
        guard reader.startReading() else { throw MulticamError("Cannot start reading: \(reader.error?.localizedDescription ?? "unknown")") }
        guard writer.startWriting() else { throw MulticamError("Cannot start writing: \(writer.error?.localizedDescription ?? "unknown")") }
        writer.startSession(atSourceTime: .zero)
        let duration = edit.duration
        let cancelled = CancelFlag()
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await pump(output: videoOutput, input: videoInput, label: "video", cancelled: cancelled) { time in
                        progress(min(1, time / max(duration, 0.001)))
                    }
                }
                if let audioOutput, let audioInput {
                    group.addTask { try await pump(output: audioOutput, input: audioInput, label: "audio", cancelled: cancelled) { _ in } }
                }
                try await group.waitForAll()
            }
        } onCancel: {
            cancelled.set()
        }
        if cancelled.value || Task.isCancelled {
            reader.cancelReading(); writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw MulticamError("Reading the footage failed: \(reader.error?.localizedDescription ?? "unknown error")")
        }
        trace("finishing writer")
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MulticamError("Writing the video failed: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        // Atomic replace on the same volume; no backup copies are left behind.
        if rename(temporary.path, url.path) != 0 {
            throw MulticamError("Could not save \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        progress(1)
    }

    static func videoSettings(_ spec: OutputSpec) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoWidthKey: spec.width, AVVideoHeightKey: spec.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        switch spec.codec {
        case .prores:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .h264, .hevc:
            settings[AVVideoCodecKey] = spec.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: spec.bitrate,
                AVVideoExpectedSourceFrameRateKey: spec.fps,
                AVVideoMaxKeyFrameIntervalKey: spec.fps * 2,
                AVVideoAllowFrameReorderingKey: true,
            ]
            compression[AVVideoProfileLevelKey] = spec.codec == .h264 ? AVVideoProfileLevelH264HighAutoLevel
                : kVTProfileLevel_HEVC_Main_AutoLevel as String
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        return settings
    }

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    final class Box: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        init(_ output: AVAssetReaderOutput, _ input: AVAssetWriterInput) { self.output = output; self.input = input }
    }

    static func pump(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String, cancelled: CancelFlag,
                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let box = Box(output, input)
        let queue = DispatchQueue(label: "multicam.export.\(label)", qos: .userInitiated)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            var lastReport = -1.0
            box.input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while box.input.isReadyForMoreMediaData {
                    if cancelled.value {
                        finished = true
                        box.input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard let sample = box.output.copyNextSampleBuffer() else {
                        finished = true
                        box.input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    if !box.input.append(sample) {
                        finished = true
                        continuation.resume(throwing: MulticamError("The encoder stopped while writing \(label)."))
                        return
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if time - lastReport >= 0.25 { lastReport = time; progress(time) }
                }
            }
        }
    }
}
