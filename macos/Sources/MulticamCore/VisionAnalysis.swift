import Accelerate
import AVFoundation
import CoreGraphics
import Foundation

/// Per-recording picture scores. A port of vision.py; keep the two in step.
public struct VisionScores: Codable, Sendable, Hashable {
    public var times: [Double] = []      // source seconds (presentation time)
    public var usable: [Double] = []     // 0-1: not dark, blurred, blocked or being handled
    public var activity: [Double] = []   // 0-1: movement inside the frame
    public var focus: [Double] = [0.5, 0.5]
    public var path: String = ""
    public init() {}
}

public enum VisionAnalysis {
    static let size = 96
    static let version = 3

    /// Grey 96x96 thumbnails about once a second, decoded from nearby keyframes only.
    static func samples(_ url: URL, every interval: Double = 1.0,
                        progress: ((Double) -> Void)? = nil) async throws -> ([Double], [[Float]]) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: interval / 2, preferredTimescale: 600)
        let count = max(1, Int(duration / interval))
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * interval, preferredTimescale: 600) }
        var results = [(Double, [Float])]()
        results.reserveCapacity(count)
        let space = CGColorSpaceCreateDeviceGray()
        var seen = Set<Int64>()
        var done = 0
        for await result in generator.images(for: times) {
            done += 1
            if Task.isCancelled { throw CancellationError() }
            if done % 50 == 0 { progress?(Double(done) / Double(count)) }
            guard let image = try? result.image, let actual = try? result.actualTime else { continue }
            // Neighbouring requests can snap to the same keyframe; keep one copy.
            if !seen.insert(actual.value * 1000 / Int64(max(1, actual.timescale))).inserted { continue }
            var pixels = [UInt8](repeating: 0, count: size * size)
            pixels.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                              bytesPerRow: size, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
            results.append((actual.seconds, pixels.map { Float($0) / 255 }))
        }
        results.sort { $0.0 < $1.0 }
        return (results.map(\.0), results.map(\.1))
    }

    /// Translation between two frames by phase correlation (128x128 padded FFT).
    final class ShiftEstimator {
        let n = 128, log2n: vDSP_Length = 7
        let setup: FFTSetup
        let window: [Float]
        init() {
            setup = vDSP_create_fftsetup(7, FFTRadix(kFFTRadix2))!
            let h = (0..<VisionAnalysis.size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(VisionAnalysis.size - 1))) }
            window = (0..<(VisionAnalysis.size * VisionAnalysis.size)).map { h[$0 / VisionAnalysis.size] * h[$0 % VisionAnalysis.size] }
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        func spectrum(_ frame: [Float]) -> ([Float], [Float]) {
            var real = [Float](repeating: 0, count: n * n), imag = [Float](repeating: 0, count: n * n)
            let s = VisionAnalysis.size
            for y in 0..<s { for x in 0..<s { real[y * n + x] = frame[y * s + x] * window[y * s + x] } }
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0, log2n, log2n, FFTDirection(FFT_FORWARD))
            }}
            return (real, imag)
        }

        func shift(_ a: ([Float], [Float]), _ b: ([Float], [Float])) -> Double {
            var real = [Float](repeating: 0, count: n * n), imag = [Float](repeating: 0, count: n * n)
            for k in 0..<(n * n) {
                let ar = a.0[k], ai = a.1[k], br = b.0[k], bi = b.1[k]
                var cr = ar * br + ai * bi, ci = ai * br - ar * bi
                let m = (cr * cr + ci * ci).squareRoot() + 1e-9
                cr /= m; ci /= m
                real[k] = cr; imag[k] = ci
            }
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0, log2n, log2n, FFTDirection(FFT_INVERSE))
            }}
            var best: Float = -.infinity, index = 0
            for k in 0..<(n * n) where real[k] > best { best = real[k]; index = k }
            var y = index / n, x = index % n
            if y > n / 2 { y -= n }
            if x > n / 2 { x -= n }
            // Shifts are in padded pixels; equal to frame pixels here.
            return Double(hypot(Double(x), Double(y)))
        }
    }

    static func median(_ v: [Double]) -> Double { MusicAnalysis.percentile(v, 50) }

    public static func score(times: [Double], frames: [[Float]]) -> VisionScores {
        var result = VisionScores()
        let n = frames.count
        guard n > 0 else { return result }
        let s = size, pixels = s * s
        var brightness = [Double](repeating: 0, count: n), sharpness = brightness, deviation = brightness
        var motion = brightness, shift = brightness
        // Median reference frame.
        var reference = [Float](repeating: 0, count: pixels)
        var column = [Float](repeating: 0, count: n)
        for p in 0..<pixels {
            for i in 0..<n { column[i] = frames[i][p] }
            column.sort()
            reference[p] = n % 2 == 1 ? column[n / 2] : (column[n / 2 - 1] + column[n / 2]) / 2
        }
        let estimator = ShiftEstimator()
        var previousSpectrum: ([Float], [Float])?
        for i in 0..<n {
            let f = frames[i]
            brightness[i] = Double(vDSP.mean(f))
            var lap = 0.0
            for y in 1..<(s - 1) { for x in 1..<(s - 1) {
                let c = f[y * s + x]
                lap += Double(abs(4 * c - f[(y - 1) * s + x] - f[(y + 1) * s + x] - f[y * s + x - 1] - f[y * s + x + 1]))
            }}
            sharpness[i] = lap / Double((s - 2) * (s - 2))
            var dev = 0.0
            for p in 0..<pixels { dev += Double(abs(f[p] - reference[p])) }
            deviation[i] = dev / Double(pixels)
            let spectrum = estimator.spectrum(f)
            if i > 0 {
                var m = 0.0
                let g = frames[i - 1]
                for p in 0..<pixels { m += Double(abs(f[p] - g[p])) }
                motion[i] = m / Double(pixels)
                shift[i] = estimator.shift(spectrum, previousSpectrum!)
            }
            previousSpectrum = spectrum
        }
        if n > 1 { motion[0] = motion[1]; shift[0] = shift[1] }
        func ratio(_ x: [Double]) -> [Double] { let m = max(median(x), 1e-6); return x.map { $0 / m } }
        func clip(_ v: Double) -> Double { min(1, max(0, v)) }
        let b = ratio(brightness), sh = ratio(sharpness)
        let d75 = max(MusicAnalysis.percentile(deviation, 75), 1e-6)
        let act = ratio(motion.map { $0 + 1e-4 })
        var usable = [Double](repeating: 1, count: n), activity = usable
        for i in 0..<n {
            usable[i] = clip((b[i] - 0.25) / 0.35) * clip((sh[i] - 0.35) / 0.35)
                * clip(1 - (deviation[i] / d75 - 1.6) / 1.4) * clip(1 - (shift[i] - 3) / 6)
            activity[i] = clip(act[i] / 2.5) * clip(1 - (shift[i] - 2) / 6)
        }
        // Centroid of frame-to-frame change over good samples, pulled toward the centre.
        let good = (1..<max(1, n)).filter { usable[$0] > 0.5 && shift[$0] < 3 }
        if good.count >= 5 {
            var change = [Double](repeating: 0, count: pixels)
            for i in good { let f = frames[i], g = frames[i - 1]; for p in 0..<pixels { change[p] += Double(abs(f[p] - g[p])) } }
            change = change.map { $0 / Double(good.count) }
            let floor = MusicAnalysis.percentile(change, 60)
            var total = 0.0, sx = 0.0, sy = 0.0
            for p in 0..<pixels {
                let w = max(0, change[p] - floor)
                total += w; sx += w * Double(p % s); sy += w * Double(p / s)
            }
            if total > 1e-6 {
                let cx = (sx / total + 0.5) / Double(s), cy = (sy / total + 0.5) / Double(s)
                result.focus = [((0.7 * cx + 0.15) * 1000).rounded() / 1000, ((0.7 * cy + 0.15) * 1000).rounded() / 1000]
            }
        }
        result.times = times
        result.usable = usable.map { ($0 * 1000).rounded() / 1000 }
        result.activity = activity.map { ($0 * 1000).rounded() / 1000 }
        return result
    }

    /// Scores for one recording, cached by file identity in `cacheDirectory`.
    public static func analyse(_ url: URL, cacheDirectory: URL?, progress: ((Double) -> Void)? = nil) async throws -> VisionScores {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = "v\(version):\(url.standardizedFileURL.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let cached = cacheDirectory?.appendingPathComponent("vision-\(Cache.key(identity)).json")
        if let cached, let data = try? Data(contentsOf: cached), let scores = try? JSONDecoder().decode(VisionScores.self, from: data) {
            return scores
        }
        let (times, frames) = try await samples(url, progress: progress)
        var result = score(times: times, frames: frames)
        result.path = url.path
        if let cached {
            try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(result).write(to: cached, options: .atomic)
        }
        return result
    }
}

public enum Cache {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Multicam Studio", isDirectory: true)
    }

    /// Short stable hash (FNV-1a, 64-bit) for cache file names.
    public static func key(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }
}
