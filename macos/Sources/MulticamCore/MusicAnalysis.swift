import Accelerate
import Foundation

/// Tempo, beat grid, bars and sections of a DJ set. A port of music.py; keep the two in step.
public struct MusicInfo: Codable, Sendable, Hashable {
    public struct Section: Codable, Sendable, Hashable {
        public var start: Double
        public var end: Double
        public var kind: String   // normal, breakdown, build, drop
        public init(start: Double, end: Double, kind: String) { self.start = start; self.end = end; self.kind = kind }
    }
    public var bpm: Double?
    public var confidence: Double = 0
    public var beats: [Double] = []
    public var downbeats: [Double] = []
    public var barStarts: [Double] = []
    public var barEnergy: [Double] = []
    public var sections: [Section] = []
    public var drops: [Double] = []
    public var duration: Double = 0
    public var hasGrid: Bool { confidence >= 0.35 && beats.count > 16 }

    public init(duration: Double = 0) { self.duration = duration }

    enum CodingKeys: String, CodingKey {
        case bpm, confidence, beats, downbeats, sections, drops, duration
        case barStarts = "bar_starts", barEnergy = "bar_energy"
    }

    public func section(at t: Double) -> String {
        sections.first { $0.start <= t && t < $0.end }?.kind ?? "normal"
    }
}

public enum MusicAnalysis {
    static let sr = 8000.0
    static let hop = 80
    static let frame = 512
    static let fps = 100.0
    static let minBPM = 70.0, maxBPM = 190.0
    static let tightness = 120.0

    // MARK: helpers mirroring NumPy

    /// Edge-padded running mean with the same alignment as music.smooth.
    static func smooth(_ v: [Double], _ size: Int) -> [Double] {
        let size = max(1, size)
        guard size > 1, !v.isEmpty else { return v }
        let left = size / 2, right = size - 1 - size / 2
        func at(_ i: Int) -> Double { v[min(max(i, 0), v.count - 1)] }
        var acc = 0.0
        for j in 0..<size { acc += at(j - left) }
        var out = [Double](repeating: 0, count: v.count)
        out[0] = acc / Double(size)
        if v.count > 1 {
            for i in 1..<v.count {
                acc += at(i + right) - at(i - 1 - left)
                out[i] = acc / Double(size)
            }
        }
        return out
    }

    static func percentile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let position = q / 100 * Double(s.count - 1)
        let i = Int(position.rounded(.down)), f = position - Double(i)
        return i + 1 < s.count ? s[i] + (s[i + 1] - s[i]) * f : s[i]
    }

    static func median(_ v: [Double]) -> Double { percentile(v, 50) }

    // MARK: features

    struct Features { var flux: [[Double]]; var rms: [Double]; var energy: [[Double]] }

    static func bandFlux(_ samples: [Float]) -> Features {
        let count = max(0, (samples.count - frame) / hop + 1)
        var flux = [[Double]](repeating: [Double](repeating: 0, count: count), count: 3)
        var energy = flux
        var rms = [Double](repeating: 0, count: count)
        guard count >= 10 else { return Features(flux: flux, rms: rms, energy: energy) }
        let window = (0..<frame).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frame - 1))) }
        let bins = frame / 2 + 1
        let freqs = (0..<bins).map { Double($0) * sr / Double(frame) }
        let bands: [[Int]] = [
            (0..<bins).filter { freqs[$0] >= 30 && freqs[$0] < 150 },
            (0..<bins).filter { freqs[$0] >= 150 && freqs[$0] < 2000 },
            (0..<bins).filter { freqs[$0] >= 2000 },
        ]
        let log2n = vDSP_Length(9)
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        defer { vDSP_destroy_fftsetup(setup) }
        var previous = [Double](repeating: 0, count: bins)
        var current = [Double](repeating: 0, count: bins)
        var buffer = [Float](repeating: 0, count: frame)
        var real = [Float](repeating: 0, count: frame / 2), imag = [Float](repeating: 0, count: frame / 2)
        samples.withUnsafeBufferPointer { input in
            for f in 0..<count {
                let start = f * hop
                vDSP_vmul(input.baseAddress! + start, 1, window, 1, &buffer, 1, vDSP_Length(frame))
                var ms: Float = 0
                vDSP_measqv(buffer, 1, &ms, vDSP_Length(frame))
                rms[f] = Double(ms).squareRoot()
                real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    buffer.withUnsafeBufferPointer { b in
                        b.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frame / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(frame / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }}
                // vDSP's forward transform is twice NumPy's rfft.
                current[0] = log1p(100 * Double(abs(real[0])) / 2)
                current[bins - 1] = log1p(100 * Double(abs(imag[0])) / 2)
                for k in 1..<(frame / 2) {
                    let magnitude = (Double(real[k]) * Double(real[k]) + Double(imag[k]) * Double(imag[k])).squareRoot() / 2
                    current[k] = log1p(100 * magnitude)
                }
                if f == 0 { previous = current }
                for (b, indices) in bands.enumerated() {
                    var d = 0.0, e = 0.0
                    for k in indices { d += max(0, current[k] - previous[k]); e += current[k] }
                    flux[b][f] = d / Double(indices.count)
                    energy[b][f] = e / Double(indices.count)
                }
                swap(&previous, &current)
            }
        }
        return Features(flux: flux, rms: rms, energy: energy)
    }

    static func normalise(_ onset: [Double]) -> [Double] {
        let local = smooth(onset, Int(fps * 3)).map { $0 + 1e-6 }
        let value = zip(onset, local).map { $0 / $1 }
        let slow = smooth(value, Int(fps / 2))
        return zip(value, slow).map { max(0, $0 - $1) }
    }

    static func tempoCurve(_ onset: [Double]) -> ([Double], Double)? {
        let window = Int(fps * 12), hop = Int(fps * 3)
        let lags = Array(Int(fps * 60 / maxBPM)...Int(fps * 60 / minBPM))
        let prior = lags.map { lag -> Double in
            let bpm = 60 * fps / Double(lag)
            return exp(-0.5 * pow(log2(bpm / 128) / 0.7, 2))
        }
        let fft = RealFFT(minimumSize: 2 * window)
        var centres = [Double](), periods = [Double](), strengths = [Double]()
        var start = 0
        let last = max(1, onset.count - window + 1)
        while start < last {
            defer { start += hop }
            let slice = Array(onset[start..<min(onset.count, start + window)])
            if slice.count < window / 2 { continue }
            let mean = slice.reduce(0, +) / Double(slice.count)
            let x = slice.map { Float($0 - mean) }
            if !x.contains(where: { $0 != 0 }) { continue }
            let spectrum = x.withUnsafeBufferPointer { fft.forward($0) }
            let acfFull = fft.correlate(spectrum, spectrum)
            let acf0 = Double(acfFull[0])
            guard acf0 > 0 else { continue }
            let n = x.count
            var score = [Double](repeating: 0, count: lags.count)
            for (i, lag) in lags.enumerated() {
                score[i] = (Double(acfFull[lag]) + 0.5 * Double(acfFull[min(2 * lag, n - 1)])) / acf0 * prior[i]
            }
            let k = score.indices.max(by: { score[$0] < score[$1] })!
            var lag = Double(lags[k])
            if k > 0 && k < lags.count - 1 {
                let a = score[k - 1], b = score[k], c = score[k + 1], d = a - 2 * b + c
                if d < 0 { lag += 0.5 * (a - c) / d }
            }
            centres.append(Double(start) + Double(window) / 2)
            periods.append(lag)
            strengths.append(Double(acfFull[lags[k]]) / acf0)
        }
        guard !periods.isEmpty else { return nil }
        let padded = [periods[0], periods[0]] + periods + [periods.last!, periods.last!]
        let medianed = (0..<periods.count).map { median(Array(padded[$0..<($0 + 5)])) }
        var curve = [Double](repeating: 0, count: onset.count)
        var j = 0
        for t in 0..<onset.count {
            let x = Double(t)
            if x <= centres[0] { curve[t] = medianed[0]; continue }
            if x >= centres.last! { curve[t] = medianed.last!; continue }
            while centres[j + 1] < x { j += 1 }
            let f = (x - centres[j]) / (centres[j + 1] - centres[j])
            curve[t] = medianed[j] + (medianed[j + 1] - medianed[j]) * f
        }
        return (curve, median(strengths))
    }

    static func trackBeats(_ onset: [Double], _ period: [Double]) -> [Double] {
        let n = onset.count
        var score = onset
        var back = [Int](repeating: -1, count: n)
        for t in 0..<n {
            let p = period[t]
            let lo = max(0, Int(Double(t) - 2 * p)), hi = Int(Double(t) - p / 2)
            if hi <= 0 || hi <= lo { continue }
            var bestValue = -Double.infinity, bestIndex = lo
            for prev in lo..<hi {
                let l = log(Double(t - prev) / p)
                let value = score[prev] - tightness * l * l
                if value > bestValue { bestValue = value; bestIndex = prev }
            }
            if bestValue > 0 { score[t] = onset[t] + bestValue; back[t] = bestIndex }
        }
        let tail = max(1, Int(period[n - 1]))
        var t = n - tail
        var best = -Double.infinity
        for i in (n - tail)..<n where score[i] > best { best = score[i]; t = i }
        var beats = [Double]()
        while t >= 0 { beats.append(Double(t)); t = back[t] }
        return beats.reversed()
    }

    static func refine(_ beats: [Double]) -> [Double] {
        let n = beats.count
        var out = beats
        for i in 0..<n {
            let lo = max(0, i - 8), hi = min(n, i + 9)
            let k = (lo..<hi).map(Double.init), y = Array(beats[lo..<hi])
            let mk = k.reduce(0, +) / Double(k.count), my = y.reduce(0, +) / Double(y.count)
            let sxy = zip(k, y).map { ($0 - mk) * ($1 - my) }.reduce(0, +)
            let sxx = k.map { ($0 - mk) * ($0 - mk) }.reduce(0, +)
            guard sxx > 0 else { continue }
            let slope = sxy / sxx, intercept = my - slope * mk
            let predicted = slope * Double(i) + intercept
            if abs(predicted - beats[i]) < 0.15 * slope { out[i] = predicted }
        }
        return out
    }

    static func barPhase(_ beats: [Double], frames: Int, flux: [[Double]], energy: [[Double]]) -> [Int] {
        let n = beats.count
        var phases = [Int](repeating: 0, count: n)
        guard n >= 8 else { return phases }
        let index = beats.map { min(max(Int($0), 0), frames - 1) }
        let profile = energy.map { smooth($0, Int(fps / 8)) }
        // Prefix sums make each beat-span mean O(1).
        let prefix = profile.map { band -> [Double] in
            var p = [0.0]; p.reserveCapacity(band.count + 1)
            for v in band { p.append(p.last! + v) }
            return p
        }
        var novelty = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let a = index[i - 1], b = index[i], c = index[i + 1]
            guard b > a, c > b else { continue }
            var total = 0.0
            for p in prefix {
                total += abs((p[c] - p[b]) / Double(c - b) - (p[b] - p[a]) / Double(b - a))
            }
            novelty[i] = total + 0.5 * flux[0][b]
        }
        let window = 32
        var choice = [(Int, Int)]()
        var start = 0
        while start < n {
            let lo = max(0, start - window / 2), hi = min(n, start + window)
            var sums = [Double](repeating: 0, count: 4)
            for k in 0..<4 {
                let ids = (lo..<hi).filter { $0 % 4 == k }
                sums[k] = ids.isEmpty ? 0 : ids.map { novelty[$0] }.reduce(0, +) / Double(ids.count)
            }
            choice.append((start, sums.indices.max(by: { sums[$0] < sums[$1] })!))
            start += window / 2
        }
        var current = choice[0].1
        var pending: Int?
        for (start, phase) in choice {
            if phase != current {
                if pending == phase { current = phase; pending = nil } else { pending = phase }
            } else { pending = nil }
            for i in start..<min(n, start + window / 2) { phases[i] = current }
        }
        return phases
    }

    static func sections(_ bass: [Double]) -> [String] {
        let count = bass.count
        var labels = [String](repeating: "normal", count: count)
        guard count >= 8 else { return labels }
        let context = (0..<count).map { percentile(Array(bass[max(0, $0 - 48)..<min(count, $0 + 48)]), 75) }
        var quiet = (0..<count).map { context[$0] - bass[$0] > 1.5 }
        for i in 1..<(count - 1) where quiet[i - 1] == quiet[i + 1] && quiet[i] != quiet[i - 1] { quiet[i] = quiet[i - 1] }
        var i = 0
        while i < count {
            if !quiet[i] { i += 1; continue }
            var j = i
            while j < count && quiet[j] { j += 1 }
            if j - i >= 4 {
                for k in i..<j { labels[k] = "breakdown" }
                let build = min(4, max(1, (j - i) / 3))
                for k in (j - build)..<j { labels[k] = "build" }
                if j < count && j - i >= 6 { for k in j..<min(count, j + 16) { labels[k] = "drop" } }
            }
            i = j
        }
        return labels
    }

    // MARK: entry point

    public static func analyse(_ samples: [Float], duration: Double? = nil) -> MusicInfo {
        let duration = duration ?? Double(samples.count) / sr
        var info = MusicInfo(duration: duration)
        guard duration >= 8 else { return info }
        let features = bandFlux(samples)
        let flux = features.flux
        let frames = flux[0].count
        guard frames > 100 else { return info }
        let onset = normalise((0..<frames).map { flux[0][$0] * 1.5 + flux[1][$0] + 0.5 * flux[2][$0] })
        guard let (period, strength) = tempoCurve(onset) else { return info }
        let raw = trackBeats(onset, period)
        guard raw.count >= 16 else { return info }
        let beats = refine(raw)
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }
        let medianInterval = median(intervals)
        info.bpm = (60 * fps / medianInterval * 100).rounded() / 100
        let regularity = Double(intervals.filter { abs($0 / medianInterval - 1) < 0.08 }.count) / Double(intervals.count)
        let onBeat = raw.map { onset[Int($0)] }.reduce(0, +) / Double(raw.count)
        var offSum = 0.0
        for i in 0..<(raw.count - 1) { offSum += onset[min(frames - 1, max(0, Int(raw[i] + (raw[i + 1] - raw[i]) / 2)))] }
        let offBeat = offSum / Double(raw.count - 1)
        let contrast = onBeat / (offBeat + 1e-6)
        info.confidence = max(0, min(1, regularity * min(1, (contrast - 1) / 1.5) * min(1, strength * 3)))
        let phases = barPhase(beats, frames: frames, flux: flux, energy: features.energy)
        let times = beats.map { $0 / fps }
        info.beats = times.map { ($0 * 1000).rounded() / 1000 }
        info.downbeats = times.indices.filter { $0 % 4 == phases[$0] }.map { (times[$0] * 1000).rounded() / 1000 }
        var barStarts = info.downbeats
        if barStarts.isEmpty || barStarts[0] > 0.5 { barStarts.insert(0, at: 0) }
        let edges = barStarts + [duration]
        let db = features.rms.map { 20 * log10(max($0, 1e-6)) }
        var bass = [Double](), loudness = [Double](), busy = [Double]()
        for (a, b) in zip(edges, edges.dropFirst()) {
            let lo = min(frames - 1, Int(a * fps)), hi = min(frames, max(lo + 1, Int(b * fps)))
            let count = Double(hi - lo)
            bass.append(features.energy[0][lo..<hi].reduce(0, +) / count)
            loudness.append(db[lo..<hi].reduce(0, +) / count)
            busy.append(onset[lo..<hi].reduce(0, +) / count)
        }
        let labels = sections(bass)
        var sections = [MusicInfo.Section]()
        for (k, label) in labels.enumerated() {
            let a = (edges[k] * 1000).rounded() / 1000, b = (edges[k + 1] * 1000).rounded() / 1000
            if let last = sections.last, last.kind == label { sections[sections.count - 1].end = b }
            else { sections.append(.init(start: a, end: b, kind: label)) }
        }
        info.sections = sections
        info.drops = sections.filter { s in
            s.kind == "drop" && sections.contains { ($0.kind == "build" || $0.kind == "breakdown") && abs($0.end - s.start) < 0.01 }
        }.map(\.start)
        func unit(_ x: [Double]) -> [Double] {
            let lo = percentile(x, 5), hi = percentile(x, 95)
            return x.map { min(1, max(0, ($0 - lo) / max(1e-6, hi - lo))) }
        }
        let (u1, u2, u3) = (unit(loudness), unit(bass), unit(busy))
        info.barEnergy = (0..<u1.count).map { (i: Int) -> Double in
            let mean: Double = (u1[i] + u2[i] + u3[i]) / 3
            return (mean * 1000).rounded() / 1000
        }
        info.barStarts = barStarts.map { ($0 * 1000).rounded() / 1000 }
        return info
    }

    public static func analyse(url: URL) async throws -> MusicInfo {
        let samples = try await Media.decodeAudio(url, sampleRate: sr)
        return analyse(samples)
    }
}
