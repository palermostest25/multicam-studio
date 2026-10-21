import AVFoundation
import Accelerate
import CoreMedia

/// What the editor needs to know about a recording.
public struct MediaInfo: Sendable, Hashable {
    public var url: URL
    public var duration: Double            // video track duration (audio for audio-only files)
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var naturalSize: CGSize         // encoded pixels
    public var orientedSize: CGSize        // after the rotation stored by the camera
    public var transform: CGAffineTransform
    public var frameRate: Double
    public var videoStart: Double          // first video sample time
    public var audioStart: Double
    public var isHDR: Bool
    public var creationDate: Date? = nil   // when recording started (camera clock)

    public var aspect: Double { orientedSize.height > 0 ? orientedSize.width / orientedSize.height : 16.0 / 9 }
}

public enum Media {
    public static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "flac", "mp3", "m4a", "aac", "caf"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    public static func info(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        guard video != nil || audio != nil else { throw MulticamError("\(url.lastPathComponent) has no audio or video.") }
        var info = MediaInfo(url: url, duration: 0, hasVideo: video != nil, hasAudio: audio != nil,
                             naturalSize: .zero, orientedSize: .zero, transform: .identity,
                             frameRate: 30, videoStart: 0, audioStart: 0, isHDR: false)
        if let video {
            let (size, transform, rate, range) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .timeRange)
            info.naturalSize = size
            info.transform = transform
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            info.orientedSize = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
            info.frameRate = Double(rate > 0 ? rate : 30)
            info.duration = range.duration.seconds
            info.videoStart = range.start.seconds
            let characteristics = try await video.load(.mediaCharacteristics)
            info.isHDR = characteristics.contains(.containsHDRVideo)
        }
        if let audio {
            let range = try await audio.load(.timeRange)
            info.audioStart = range.start.seconds
            if video == nil { info.duration = range.duration.seconds }
        }
        if let item = try? await asset.load(.creationDate), let date = try? await item.load(.dateValue) {
            info.creationDate = date
        }
        if !info.duration.isFinite || info.duration <= 0 {
            info.duration = try await asset.load(.duration).seconds
        }
        guard info.duration.isFinite, info.duration > 0 else { throw MulticamError("Cannot read the duration of \(url.lastPathComponent).") }
        return info
    }

    /// Mono Float32 samples at `sampleRate`, decoded by AVFoundation (hardware where possible).
    /// Only the audio track is read, so a 20 GB 4K file is not read in full.
    public static func decodeAudio(_ url: URL, sampleRate: Double = 8000,
                                   progress: ((Double) -> Void)? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio).first
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let track else { throw MulticamError("\(url.lastPathComponent) has no audio track.") }
        var nativeRate = sampleRate
        if let format = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mSampleRate > 0 {
            nativeRate = asbd.mSampleRate
        }
        // Decode at the file's own rate (mono), then resample with AVAudioConverter primed for
        // zero latency. AVAssetReader's built-in converter adds a rate-dependent delay that
        // differs between 44.1 kHz bounces and 48 kHz cameras, which would skew sync.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: nativeRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw MulticamError("Cannot decode \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")") }
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate, channels: 1, interleaved: false)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let converter = nativeRate == sampleRate ? nil : AVAudioConverter(from: inFormat, to: outFormat)
        converter?.primeMethod = .normal
        converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        var samples = [Float]()
        samples.reserveCapacity(Int(max(0, duration) * sampleRate) + 4096)
        var lastReport = 0.0
        var pending = [Float]()
        func convert(final: Bool) throws {
            guard let converter else { samples.append(contentsOf: pending); pending.removeAll(keepingCapacity: true); return }
            let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(max(1, pending.count)))!
            input.frameLength = AVAudioFrameCount(pending.count)
            if !pending.isEmpty { pending.withUnsafeBufferPointer { memcpy(input.floatChannelData![0], $0.baseAddress!, pending.count * 4) } }
            pending.removeAll(keepingCapacity: true)
            var supplied = false
            let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / nativeRate) + 2048
            while true {
                let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)!
                var error: NSError?
                let status = converter.convert(to: out, error: &error) { _, state in
                    if supplied {
                        state.pointee = final ? .endOfStream : .noDataNow
                        return nil
                    }
                    supplied = true
                    state.pointee = .haveData
                    return input
                }
                if let error { throw error }
                if out.frameLength > 0 {
                    samples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
                }
                if status == .endOfStream || status == .inputRanDry || status == .error || out.frameLength == 0 { break }
            }
        }
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                pending.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
            if pending.count >= 1 << 18 { try convert(final: false) }
            if let progress, duration > 0 {
                let fraction = Double(samples.count) / sampleRate / duration
                if fraction - lastReport > 0.02 { lastReport = fraction; progress(min(1, fraction)) }
            }
        }
        if reader.status == .failed { throw MulticamError("Audio decoding failed for \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "")") }
        try convert(final: true)
        return samples
    }
}

/// Second-order IIR filters, like FFmpeg's highpass/lowpass (Butterworth Q).
public enum Biquad {
    public static func apply(_ x: inout [Float], highpass: Double? = nil, lowpass: Double? = nil, sampleRate: Double) {
        func run(_ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) {
            var coefficients = [b0, b1, b2, a1, a2]
            guard let setup = vDSP_biquad_CreateSetup(&coefficients, 1) else { return }
            defer { vDSP_biquad_DestroySetup(setup) }
            var delay = [Float](repeating: 0, count: 4)
            let input = x
            x.withUnsafeMutableBufferPointer { out in
                input.withUnsafeBufferPointer { inp in
                    vDSP_biquad(setup, &delay, inp.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(inp.count))
                }
            }
        }
        let q = 1 / 2.0.squareRoot()
        if let f = highpass {
            let w = 2 * Double.pi * f / sampleRate, alpha = sin(w) / (2 * q), cw = cos(w), a0 = 1 + alpha
            run((1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0, -2 * cw / a0, (1 - alpha) / a0)
        }
        if let f = lowpass {
            let w = 2 * Double.pi * f / sampleRate, alpha = sin(w) / (2 * q), cw = cos(w), a0 = 1 + alpha
            run((1 - cw) / 2 / a0, (1 - cw) / a0, (1 - cw) / 2 / a0, -2 * cw / a0, (1 - alpha) / a0)
        }
    }
}
