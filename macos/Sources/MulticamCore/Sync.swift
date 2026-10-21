import Accelerate
import Foundation

/// Real FFT of a fixed power-of-two size (vDSP packed format).
final class RealFFT {
    let log2n: vDSP_Length
    let n: Int
    private let setup: FFTSetup

    init(minimumSize: Int) {
        var l: vDSP_Length = 1
        while (1 << l) < minimumSize { l += 1 }
        log2n = l
        n = 1 << Int(l)
        setup = vDSP_create_fftsetup(l, FFTRadix(kFFTRadix2))!
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    /// Forward transform of `x` zero-padded to n. Returns (real, imag) halves.
    func forward(_ x: UnsafeBufferPointer<Float>) -> ([Float], [Float]) {
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var padded = [Float](repeating: 0, count: n)
        _ = padded.withUnsafeMutableBufferPointer { memcpy($0.baseAddress!, x.baseAddress!, min(x.count, n) * 4) }
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                padded.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        return (real, imag)
    }

    /// Circular cross-correlation sum_j x[k+j] t[j], given both spectra.
    func correlate(_ x: ([Float], [Float]), _ t: ([Float], [Float])) -> [Float] {
        let half = n / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        x.0.withUnsafeBufferPointer { xr in x.1.withUnsafeBufferPointer { xi in
        t.0.withUnsafeBufferPointer { tr in t.1.withUnsafeBufferPointer { ti in
            // X * conj(T); index 0 packs DC (real) and Nyquist (imag) separately.
            for k in 1..<half {
                let a = xr[k], b = xi[k], c = tr[k], d = ti[k]
                real[k] = a * c + b * d
                imag[k] = b * c - a * d
            }
            real[0] = xr[0] * tr[0]
            imag[0] = xi[0] * ti[0]
        }}}}
        var out = [Float](repeating: 0, count: n)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { o in
                    o.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }
        var scale = 1 / Float(4 * n)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(n))
        return out
    }
}

public struct SyncResult: Sendable, Hashable, Codable {
    public var offset: Double          // bounce time of the first video frame
    public var rate: Double            // bounce seconds per camera second
    public var matchedAnchors: Int?
    public var method: String          // "automatic" or "manual"
    public var driftPPM: Double { (rate - 1) * 1e6 }
}

/// Audio cross-correlation sync, a port of multicam_edit.py (synchronise/match_anchor/fit_sync).
public enum AudioSync {
    public static let sampleRate = 8000.0
    static let minCorrelation = 0.08
    static let maxDriftPPM = 2000.0
    static let tolerance = 0.080

    /// 8 kHz mono, band-limited to 120-3000 Hz like the Python engine.
    public static func analysisAudio(_ url: URL) async throws -> [Float] {
        var x = try await Media.decodeAudio(url, sampleRate: sampleRate)
        Biquad.apply(&x, highpass: 120, lowpass: 3000, sampleRate: sampleRate)
        if x.count < Int(sampleRate) { throw MulticamError("Less than one second of usable audio: \(url.lastPathComponent)") }
        return x
    }

    /// Best start of `template` inside `reference` and its normalised correlation.
    static func matchAnchor(_ reference: [Float], _ template: ArraySlice<Float>) -> (Double, Double) {
        let m = template.count
        guard m > 0, reference.count >= m else { return (0, 0) }
        var t = Array(template)
        let mean = vDSP.mean(t)
        vDSP.add(-mean, t, result: &t)
        let energy = Double(vDSP.sumOfSquares(t))
        if energy < 1e-9 { return (0, 0) }
        let fft = RealFFT(minimumSize: min(reference.count, max(1 << 20, 2 * m)))
        let block = fft.n - m + 1
        let tSpectrum = t.withUnsafeBufferPointer { fft.forward($0) }
        var best = (0.0, 0.0)
        var start = 0
        while start <= reference.count - m {
            let stop = min(reference.count, start + block + m - 1)
            let segment = Array(reference[start..<stop])
            let spectrum = segment.withUnsafeBufferPointer { fft.forward($0) }
            let numerator = fft.correlate(spectrum, tSpectrum)
            let lags = segment.count - m + 1
            // Sliding sums for the normalisation (double precision).
            var sum = 0.0, squares = 0.0
            for j in 0..<m { let v = Double(segment[j]); sum += v; squares += v * v }
            for k in 0..<lags {
                if k > 0 {
                    let old = Double(segment[k - 1]), new = Double(segment[k + m - 1])
                    sum += new - old
                    squares += new * new - old * old
                }
                let variance = max(squares - sum * sum / Double(m), 0)
                if variance < 1e-9 { continue }
                let score = abs(Double(numerator[k])) / max(sqrt(variance * energy), 1e-10)
                if score > best.1 { best = (Double(start + k) / sampleRate, score) }
            }
            start += block
        }
        return best
    }

    struct Match { var x: Double; var y: Double; var c: Double }

    static func fit(_ matches: [Match], allowDrift: Bool) throws -> (Double, Double, Int) {
        let good = matches.filter { $0.c >= minCorrelation }
        guard good.count >= 2 else {
            throw MulticamError("Too few reliable audio matches; camera audio may be silent or unrelated. Set a manual offset after checking sync.")
        }
        var models = [(median(good.map { $0.y - $0.x }), 1.0)]
        if allowDrift && good.count >= 3 {
            for i in 0..<good.count { for j in (i + 1)..<good.count where abs(good[j].x - good[i].x) >= 2 {
                let rate = (good[j].y - good[i].y) / (good[j].x - good[i].x)
                if abs(rate - 1) <= maxDriftPPM / 1e6 { models.append((good[i].y - rate * good[i].x, rate)) }
            }}
        }
        var bestMask = [Bool](), bestKey = (-1, -1.0)
        for (offset, rate) in models {
            let mask = good.map { abs($0.y - (offset + rate * $0.x)) <= tolerance }
            let key = (mask.filter { $0 }.count, zip(good, mask).filter { $1 }.map { $0.0.c }.reduce(0, +))
            if key.0 > bestKey.0 || (key.0 == bestKey.0 && key.1 > bestKey.1) { bestKey = key; bestMask = mask }
        }
        let inliers = zip(good, bestMask).filter { $1 }.map { $0.0 }
        guard inliers.count >= max(2, Int(ceil(Double(good.count) * 0.6))) else {
            throw MulticamError("Audio matches disagree (repeated music, drift or an edited recording). Check sync and set a manual offset.")
        }
        var rate = 1.0, offset = median(inliers.map { $0.y - $0.x })
        let xs = inliers.map(\.x)
        if allowDrift && inliers.count >= 3 && (xs.max()! - xs.min()!) >= 5 {
            let mx = xs.reduce(0, +) / Double(xs.count), my = inliers.map(\.y).reduce(0, +) / Double(xs.count)
            let sxy = inliers.map { ($0.x - mx) * ($0.y - my) }.reduce(0, +)
            let sxx = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
            rate = sxy / sxx; offset = my - rate * mx
        }
        if abs(rate - 1) * 1e6 > maxDriftPPM || inliers.contains(where: { abs($0.y - offset - rate * $0.x) > tolerance }) {
            throw MulticamError("Sync has inconsistent clock drift; set a checked manual offset.")
        }
        return (offset, rate, inliers.count)
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(); let n = s.count
        return n == 0 ? 0 : n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Sync one camera recording to the bounce. `samples` is the camera's analysis audio.
    public static func synchronise(camera samples: [Float], info: MediaInfo, bounce reference: [Float],
                                   allowDrift: Bool, log: (String) -> Void = { _ in }) throws -> SyncResult {
        let length = min(Int(12 * sampleRate), samples.count / 3, reference.count / 3)
        guard length >= Int(2 * sampleRate) else {
            throw MulticamError("\(info.url.lastPathComponent) is too short for automatic sync; set a manual offset.")
        }
        func matches(window: Int, anchors: Int) -> [Match] {
            // A short excerpt can be anywhere inside a long camera file: sample anchors
            // from the shorter recording, keeping x = camera time and y = bounce time.
            let reverse = reference.count < samples.count
            let shorter = reverse ? reference : samples, longer = reverse ? samples : reference
            var starts = Set<Int>()
            for i in 0..<anchors { starts.insert(Int(Double(shorter.count - window) * Double(i) / Double(max(1, anchors - 1)))) }
            let ordered = starts.sorted()
            var found = [Match](repeating: Match(x: 0, y: 0, c: 0), count: ordered.count)
            found.withUnsafeMutableBufferPointer { slots in
                DispatchQueue.concurrentPerform(iterations: ordered.count) { index in
                    let start = ordered[index]
                    let (position, score) = matchAnchor(longer, shorter[start..<(start + window)])
                    let anchor = (Double(start) + Double(window) / 2) / sampleRate
                    let hit = position + Double(window) / 2 / sampleRate
                    slots[index] = reverse ? Match(x: hit, y: anchor, c: score) : Match(x: anchor, y: hit, c: score)
                }
            }
            for m in found { log(String(format: "  audio %9.3fs -> bounce %9.3fs; correlation %.3f", m.x, m.y, m.c)) }
            return found
        }
        var result: (Double, Double, Int)
        do {
            result = try fit(matches(window: length, anchors: 7), allowDrift: allowDrift)
        } catch {
            guard length > Int(2 * sampleRate) else { throw error }
            log("  Retrying with 2-second anchors to tolerate clock drift …")
            result = try fit(matches(window: Int(2 * sampleRate), anchors: 17), allowDrift: allowDrift)
        }
        let (audioOffset, rate, count) = result
        // Camera time is measured from its first video frame, not its first audio sample.
        let offset = audioOffset + rate * (info.videoStart - info.audioStart)
        return SyncResult(offset: offset, rate: rate, matchedAnchors: count, method: "automatic")
    }
}
