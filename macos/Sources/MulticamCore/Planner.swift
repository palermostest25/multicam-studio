import Foundation

/// Smart shot planning. A port of planner.py; keep the two in step.
public struct Shot: Codable, Hashable, Sendable {
    public var start: Int          // output frame on the bounce timeline
    public var end: Int
    public var camera: Int?        // index into the coverage list, nil = black
    public var reason: String
    public init(start: Int, end: Int, camera: Int?, reason: String) {
        self.start = start; self.end = end; self.camera = camera; self.reason = reason
    }
}

/// One synced recording placed on the output frame grid.
public struct Coverage: Sendable, Hashable {
    public var angle: String
    public var first: Int
    public var last: Int
    public init(angle: String, first: Int, last: Int) { self.angle = angle; self.first = first; self.last = last }
}

public struct Rhythm: Sendable, Hashable {
    public var mainHold: (Double, Double) = (20, 60)
    public var cutawayHold: (Double, Double) = (4, 12)
    public var dropHold: (Double, Double) = (3, 6)
    public var breakdownHold: (Double, Double) = (15, 30)
    public var cutScale = 1.0
    public var mainShare = 0.7
    public var minShot = 1.2
    public var candidates = 48
    public init() {}

    public static var shortForm: Rhythm {
        var r = Rhythm()
        r.mainHold = (3, 7); r.cutawayHold = (2, 5); r.dropHold = (1.5, 4); r.breakdownHold = (4, 8)
        r.mainShare = 0.5; r.minShot = 0.9; r.candidates = 24
        return r
    }

    public static func == (a: Rhythm, b: Rhythm) -> Bool {
        a.mainHold == b.mainHold && a.cutawayHold == b.cutawayHold && a.dropHold == b.dropHold
            && a.breakdownHold == b.breakdownHold && a.cutScale == b.cutScale && a.mainShare == b.mainShare
            && a.minShot == b.minShot && a.candidates == b.candidates
    }
    public func hash(into h: inout Hasher) { h.combine(cutScale); h.combine(mainShare); h.combine(mainHold.0) }
}

/// Prefix sums of per-step scores (0.5 s steps) for fast window means.
public struct ScoreTrack: Sendable {
    public static let step = 0.5
    let prefix: [Double]
    let values: [Double]
    let steps: Int
    public init(values input: [Double?], steps: Int) {
        var p = [0.0], v = [Double]()
        p.reserveCapacity(steps + 1); v.reserveCapacity(steps)
        for i in 0..<steps {
            let x = (i < input.count ? input[i] : nil) ?? 1
            v.append(x); p.append(p.last! + x)
        }
        prefix = p; values = v; self.steps = steps
    }

    /// Start (seconds) of the first sustained poor stretch in [a, b), or nil.
    public func badFrom(_ a: Double, _ b: Double, threshold: Double = 0.35, run: Int = 3) -> Double? {
        let i = max(0, Int(a / Self.step)), j = min(steps, Int((b / Self.step).rounded(.up)))
        var count = 0
        guard i < j else { return nil }
        for k in i..<j {
            count = values[k] < threshold ? count + 1 : 0
            if count >= run { return Double(k - run + 1) * Self.step }
        }
        return nil
    }
    public func mean(_ a: Double, _ b: Double) -> Double {
        let i = max(0, min(steps, Int(a / Self.step)))
        let j = max(i + 1, min(steps, Int((b / Self.step).rounded(.up))))
        if j > steps { return 1 }
        return (prefix[j] - prefix[i]) / Double(j - i)
    }
}

public struct CameraScores: Sendable {
    public var usable: ScoreTrack
    public var activity: ScoreTrack
}

/// Deterministic generator so a seed gives the same edit every time.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

public struct ClipWindow: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var score: Double
}

public enum Planner {
    public static func scores(steps: Int, vision: [([Double?], [Double?])?]) -> [CameraScores] {
        vision.map { v in CameraScores(usable: ScoreTrack(values: v?.0 ?? [], steps: steps),
                                       activity: ScoreTrack(values: v?.1 ?? [], steps: steps)) }
    }

    public static func steps(total: Int, fps: Int) -> Int { Int((Double(total) / Double(fps) / ScoreTrack.step).rounded(.up)) + 2 }

    static func cutGrid(_ music: MusicInfo?, total: Int, fps: Int) -> ([Int], [Double]) {
        var weights = [Int: Double]()
        let f = Double(fps)
        if let music, music.hasGrid {
            for t in music.beats { let k = Int((t * f).rounded()); if k > 0 && k < total { weights[k] = 0.35 } }
            for t in music.downbeats { let k = Int((t * f).rounded()); if k > 0 && k < total { weights[k] = 1.0 } }
            for t in stride(from: 0, to: music.downbeats.count, by: 4).map({ music.downbeats[$0] }) {
                let k = Int((t * f).rounded()); if k > 0 && k < total { weights[k] = 1.6 }
            }
            for t in music.drops { let k = Int((t * f).rounded()); if k > 0 && k < total { weights[k] = 3.0 } }
        } else {
            let step = max(1, fps / 2)
            for k in stride(from: step, to: total, by: step) { weights[k] = 1 }
        }
        let frames = weights.keys.sorted()
        return (frames, frames.map { weights[$0]! })
    }

    static func section(_ sections: [MusicInfo.Section], _ t: Double) -> String {
        sections.first { $0.start <= t && t < $0.end }?.kind ?? "normal"
    }

    static func anglesAt(_ cameras: [Coverage], _ frame: Int, minimum: Int = 0) -> [(String, Int)] {
        var result = [String: Int]()
        var order = [String]()
        for (i, c) in cameras.enumerated() where c.first <= frame && frame < c.last && c.last - frame >= minimum {
            if let j = result[c.angle] { if c.last > cameras[j].last { result[c.angle] = i } }
            else { result[c.angle] = i; order.append(c.angle) }
        }
        return order.map { ($0, result[$0]!) }
    }

    static func targetHold(_ mode: String, _ isMain: Bool, _ r: Rhythm) -> Double {
        let (low, high): (Double, Double)
        switch mode {
        case "breakdown": (low, high) = isMain ? r.breakdownHold : r.cutawayHold
        case "drop": (low, high) = r.dropHold
        case "build": (low, high) = (r.dropHold.0, r.cutawayHold.0)
        default: (low, high) = isMain ? r.mainHold : r.cutawayHold
        }
        return (low + high) / 2 * r.cutScale
    }

    static func lowerBound(_ a: [Int], _ x: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) / 2; if a[m] < x { lo = m + 1 } else { hi = m } }
        return lo
    }
    static func upperBound(_ a: [Int], _ x: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) / 2; if a[m] <= x { lo = m + 1 } else { hi = m } }
        return lo
    }

    static func chooseEnd(frame: Int, hold: Double, fps: Int, minFrames: Int, end: Int, coverageEnd: Int,
                          grid: [Int], weights: [Double], boundaries: [Int], activities: [Double]) -> Int {
        let f = Double(fps)
        let limit = min(end, coverageEnd)
        if limit - frame <= minFrames { return limit }
        let target = frame + Int((hold * f).rounded())
        let i = upperBound(boundaries, frame + minFrames - 1)
        if i < boundaries.count && boundaries[i] < min(limit, target + fps) { return boundaries[i] }
        for a in activities {
            let k = Int((a * f).rounded())
            if frame + minFrames <= k && k <= min(limit, frame + Int((hold * 1.5 * f).rounded())) { return k }
        }
        let lo = frame + max(minFrames, Int((hold * 0.6 * f).rounded()))
        let hi = min(limit, frame + Int((hold * 1.5 * f).rounded()))
        if hi <= lo {
            return limit - frame >= minFrames ? max(frame + minFrames, min(limit, target)) : limit
        }
        let a = lowerBound(grid, lo), b = upperBound(grid, hi)
        var best: Int?, bestValue = -1e9
        let span = Double(max(1, hi - lo))
        for k in a..<max(a, b) {
            let value = weights[k] - 1.2 * Double(abs(grid[k] - target)) / span
            if value > bestValue { best = grid[k]; bestValue = value }
        }
        var stop = best ?? min(limit, max(lo, target))
        if limit - stop > 0 && limit - stop < minFrames { stop = limit }
        return stop
    }

    static func planOnce(_ cameras: [Coverage], start: Int, end: Int, fps: Int, grid: [Int], weights: [Double],
                         onGrid: Set<Int>, scores: [CameraScores], sections: [MusicInfo.Section], activities: [Double],
                         rng: inout SeededRandom, mainCamera: String, rhythm: Rhythm, temperature: Double) -> [Shot] {
        let f = Double(fps)
        let minFrames = max(2, Int((rhythm.minShot * min(1, max(rhythm.cutScale, 0.6)) * f).rounded()))
        var shots = [Shot]()
        var used = [String: Int](), lastSeen = [String: Int]()
        var history = [String]()
        var frame = start
        let boundaries = Set(sections.filter { $0.kind == "drop" }.map { Int(($0.start * f).rounded()) }
            .filter { start < $0 && $0 < end }).sorted()
        while frame < end {
            let t = Double(frame) / f
            let mode = section(sections, t)
            let covering = anglesAt(cameras, frame, minimum: 1)
            if covering.isEmpty {
                let next = (cameras.map(\.first).filter { $0 > frame } + [end]).min()!
                if let last = shots.last, last.camera == nil { shots[shots.count - 1].end = next }
                else { shots.append(Shot(start: frame, end: next, camera: nil, reason: "no camera coverage; black")) }
                frame = next
                continue
            }
            let previous = history.last, before = history.count > 1 ? history[history.count - 2] : nil
            let covered = max(1, used.values.reduce(0, +))
            let share = Double(used[mainCamera] ?? 0) / Double(covered)
            var options = [(Double, String, Int, Double)]()
            for (angle, index) in covering {
                if angle == previous && covering.count > 1 { continue }
                let isMain = angle == mainCamera
                let hold = targetHold(mode, isMain, rhythm)
                let horizon = min(end, frame + Int((hold * f).rounded()), cameras[index].last)
                let soon = scores[index].usable.mean(t, min(Double(horizon) / f, t + 2))
                let quality = min(scores[index].usable.mean(t, Double(horizon) / f), soon)
                let activity = scores[index].activity.mean(t, Double(horizon) / f)
                var value = 2.2 * quality
                let energetic = mode == "drop" || mode == "build"
                if isMain { value += 2.0 * (rhythm.mainShare - share) + (mode == "breakdown" || mode == "normal" ? 0.6 : 0) }
                else { value += 1.0 * (share - rhythm.mainShare) + (energetic ? 0.5 : 0) }
                value += (energetic ? 0.9 : 0.3) * activity
                if angle == before && covering.count > 2 { value -= 0.5 }
                let rest = Double(frame - (lastSeen[angle] ?? -1_000_000_000)) / f
                value += min(rest, 60) / 120
                if cameras[index].last - frame < minFrames { value -= 3 }
                if quality < 0.3 { value -= 2 }
                options.append((value, angle, index, hold))
            }
            if options.isEmpty {
                let (angle, index) = covering[0]
                options = [(0, angle, index, targetHold(mode, angle == mainCamera, rhythm))]
            }
            options.sort { ($0.0, $0.1) > ($1.0, $1.1) }
            var chosen = options[0]
            if temperature > 0 && options.count > 1 {
                let top = options[0].0
                let probabilities = options.map { exp(($0.0 - top) / temperature) }
                var pick = rng.unit() * probabilities.reduce(0, +)
                for (option, p) in zip(options, probabilities) {
                    chosen = option
                    pick -= p
                    if pick <= 0 { break }
                }
            }
            let (_, angle, index, baseHold) = chosen
            let hold = baseHold * rng.uniform(0.75, 1.25)
            // Leave a camera before its picture goes bad (lens covered, knocked, someone in front).
            var limit = cameras[index].last
            if let bad = scores[index].usable.badFrom(t + Double(minFrames) / f, Double(min(end, cameras[index].last)) / f) {
                limit = max(frame + minFrames, Int((bad * f).rounded()))
            }
            let stop = chooseEnd(frame: frame, hold: hold, fps: fps, minFrames: minFrames, end: end,
                                 coverageEnd: limit, grid: grid, weights: weights, boundaries: boundaries,
                                 activities: angle == mainCamera && mode == "normal" ? activities : [])
            let reason = mode + (onGrid.contains(stop) ? " (beat-synced)" : "")
            if let last = shots.last, last.camera == index, last.end == frame { shots[shots.count - 1].end = stop }
            else { shots.append(Shot(start: frame, end: stop, camera: index, reason: reason)) }
            used[angle, default: 0] += stop - frame
            lastSeen[angle] = stop
            history.append(angle)
            frame = stop
        }
        return absorbShort(shots, minFrames: minFrames, cameras: cameras)
    }

    static func absorbShort(_ input: [Shot], minFrames: Int, cameras: [Coverage]) -> [Shot] {
        var shots = input
        var changed = true
        while changed {
            changed = false
            for i in shots.indices where shots[i].end - shots[i].start < minFrames && shots.count > 1 {
                let s = shots[i]
                for j in [i - 1, i + 1] where j >= 0 && j < shots.count {
                    guard let cam = shots[j].camera, s.camera != nil else { continue }
                    let c = cameras[cam]
                    if c.first <= min(s.start, shots[j].start) && max(s.end, shots[j].end) <= c.last {
                        shots[j].start = min(s.start, shots[j].start); shots[j].end = max(s.end, shots[j].end)
                        shots.remove(at: i)
                        changed = true
                        break
                    }
                }
                if changed { break }
            }
        }
        var merged = [Shot]()
        for s in shots {
            if let last = merged.last, last.camera == s.camera, last.end == s.start { merged[merged.count - 1].end = s.end }
            else { merged.append(s) }
        }
        return merged
    }

    static func cost(_ shots: [Shot], _ cameras: [Coverage], fps: Int, scores: [CameraScores], mainCamera: String, rhythm: Rhythm) -> Double {
        let f = Double(fps)
        let covered = max(1, shots.filter { $0.camera != nil }.map { $0.end - $0.start }.reduce(0, +))
        let main = shots.filter { $0.camera.map { cameras[$0].angle == mainCamera } ?? false }.map { $0.end - $0.start }.reduce(0, +)
        let shareCost = pow((Double(main) / Double(covered) - rhythm.mainShare) / 0.06, 2)
        var quality = 0.0
        for s in shots { if let c = s.camera { quality += (1 - scores[c].usable.mean(Double(s.start) / f, Double(s.end) / f)) * Double(s.end - s.start) } }
        let flashes = shots.filter { $0.camera != nil && Double($0.end - $0.start) / f < rhythm.minShot * 0.6 }.count
        let black = Double(shots.filter { $0.camera == nil }.map { $0.end - $0.start }.reduce(0, +)) / f
        return shareCost + 25 * quality / Double(covered) + 10 * Double(flashes) + black
    }

    /// The best of `rhythm.candidates` plans over the frame window [start, end).
    public static func plan(cameras: [Coverage], total: Int, fps: Int, music: MusicInfo?, sections: [MusicInfo.Section],
                            activities: [Double], seed: Int, mainCamera: String, rhythm: Rhythm,
                            window: Range<Int>? = nil, scores: [CameraScores]) -> [Shot] {
        let range = window ?? 0..<total
        var rng = SeededRandom(seed: UInt64(bitPattern: Int64(seed)))
        let (grid, weights) = cutGrid(music, total: total, fps: fps)
        let onGrid = Set(grid)
        let acts = activities.sorted()
        var best: (Double, [Shot])?
        for n in 0..<max(1, rhythm.candidates) {
            var child = SeededRandom(seed: rng.next())
            let shots = planOnce(cameras, start: range.lowerBound, end: range.upperBound, fps: fps, grid: grid, weights: weights,
                                 onGrid: onGrid, scores: scores, sections: sections, activities: acts, rng: &child,
                                 mainCamera: mainCamera, rhythm: rhythm, temperature: n == 0 ? 0 : 0.35)
            let c = cost(shots, cameras, fps: fps, scores: scores, mainCamera: mainCamera, rhythm: rhythm)
            if best == nil || c < best!.0 { best = (c, shots) }
        }
        return best!.1
    }

    // MARK: manual intervals

    /// Replace exact timeline ranges with forced cameras (shot_overrides). Throws when footage is missing.
    public static func applyOverrides(_ shots: [Shot], cameras: [Coverage], paths: [String], overrides: [ShotOverride],
                                      fps: Int, duration: Double) throws -> [Shot] {
        guard !overrides.isEmpty, let total = shots.last?.end else { return shots }
        let f = Double(fps)
        var forced = [Shot]()
        var previousEnd = 0
        for item in overrides.sorted(by: { $0.start < $1.start }) {
            if item.end > duration + 1e-7 { throw MulticamError("A forced camera interval extends beyond the audio.") }
            let start = Int((item.start * f).rounded())
            let end = abs(item.end - duration) < 1e-7 ? total : Int((item.end * f).rounded())
            guard start >= 0, start < end, end <= total else { throw MulticamError("Every forced interval must cover at least one frame.") }
            guard start >= previousEnd else { throw MulticamError("Forced camera intervals overlap.") }
            previousEnd = end
            var frame = start
            while frame < end {
                let index: Int?
                if let source = item.sourcePath {
                    index = cameras.indices.first { cameras[$0].angle == item.cameraID && paths[$0] == source && cameras[$0].first <= frame && frame < cameras[$0].last }
                } else {
                    index = anglesAt(cameras, frame).first { $0.0 == item.cameraID }?.1
                }
                guard let index else {
                    throw MulticamError("Camera \(item.cameraID) has no synced footage at \(Timecode.format(Double(frame) / f)); adjust the forced interval.")
                }
                let segmentEnd = min(end, cameras[index].last)
                forced.append(Shot(start: frame, end: segmentEnd, camera: index, reason: "manual shot override"))
                frame = segmentEnd
            }
        }
        return overlay(shots, forced: forced, start: 0, end: total)
    }

    /// Lay forced shots over a plan, clipped to [start, end).
    public static func overlay(_ shots: [Shot], forced input: [Shot], start: Int, end: Int) -> [Shot] {
        let forced = input.filter { $0.end > start && $0.start < end }
            .map { Shot(start: max($0.start, start), end: min($0.end, end), camera: $0.camera, reason: $0.reason) }
        guard !forced.isEmpty else { return shots }
        let edges = Set(shots.flatMap { [$0.start, $0.end] } + forced.flatMap { [$0.start, $0.end] }).sorted()
        var result = [Shot]()
        for (a, b) in zip(edges, edges.dropFirst()) {
            guard let pick = forced.first(where: { $0.start <= a && a < $0.end }) ?? shots.first(where: { $0.start <= a && a < $0.end }) else { continue }
            if let last = result.last, last.camera == pick.camera, last.reason == pick.reason, last.end == a { result[result.count - 1].end = b }
            else { result.append(Shot(start: a, end: b, camera: pick.camera, reason: pick.reason)) }
        }
        return result
    }

    // MARK: short clips

    public static func fullyCovered(_ cameras: [Coverage], _ a: Int, _ b: Int) -> Bool {
        var frame = a
        while frame < b {
            guard let reach = cameras.filter({ $0.first <= frame && frame < $0.last }).map(\.last).max() else { return false }
            frame = reach
        }
        return true
    }

    public static func windows(music: MusicInfo?, cameras: [Coverage], total: Int, fps: Int, length: Double,
                               scores: [CameraScores]) -> [ClipWindow] {
        let f = Double(fps), duration = Double(total) / f
        let downbeats = (music?.hasGrid ?? false) ? music!.downbeats : []
        var spans = [(Double, Double, Bool)]()
        if downbeats.count > 8 {
            let bar = (downbeats.last! - downbeats[0]) / Double(max(1, downbeats.count - 1))
            var bars = max(1, Int((length / bar).rounded()))
            let four = max(4, Int((Double(bars) / 4).rounded()) * 4)
            if abs(Double(four) * bar - length) <= 0.15 * length { bars = four }
            let beats = music!.beats
            for i in downbeats.indices {
                // Count whole beats from the bar line so a misread bar phase never changes the length.
                let a = downbeats[i]
                var k = 0, lo = 0, hi = beats.count
                while lo < hi { let m = (lo + hi) / 2; if beats[m] < a - 1e-4 { lo = m + 1 } else { hi = m } }
                k = lo
                let b = k + 4 * bars < beats.count ? beats[k + 4 * bars] : a + Double(bars) * bar
                spans.append((a, b, i % 4 == 0))
            }
        } else {
            var t = 0.0
            while t <= max(0, duration - length) { spans.append((t, t + length, false)); t += 2 }
        }
        let energy = music?.barEnergy ?? [], barStarts = music?.barStarts ?? [], drops = music?.drops ?? []
        var result = [ClipWindow]()
        for (a, b, phrase) in spans {
            if b > duration + 0.01 { break }
            guard fullyCovered(cameras, Int((a * f).rounded()), Int((b * f).rounded())) else { continue }
            var level = 0.5
            if !barStarts.isEmpty && !energy.isEmpty {
                let lo = barStarts.firstIndex { $0 >= a } ?? barStarts.count
                let hi = max(lo + 1, barStarts.firstIndex { $0 >= b } ?? barStarts.count)
                let slice = energy[min(lo, energy.count)..<min(hi, energy.count)]
                level = slice.isEmpty ? 0 : slice.reduce(0, +) / Double(slice.count)
            }
            var value = level
            for d in drops {
                let position = (d - a) / max(1e-6, b - a)
                if position >= 0.12 && position <= 0.55 { value += 0.8 } else if position >= 0 && position < 0.12 { value += 0.4 }
            }
            if !scores.isEmpty {
                value += 0.3 * scores.map { $0.activity.mean(a, b) * $0.usable.mean(a, b) }.max()!
            }
            if phrase { value += 0.1 }
            result.append(ClipWindow(start: (a * 1000).rounded() / 1000, end: (b * 1000).rounded() / 1000, score: (value * 1000).rounded() / 1000))
        }
        return result
    }

    public static func choose(_ windows: [ClipWindow], count: Int, mode: ClipMode) -> [ClipWindow] {
        if mode == .sequence {
            var chosen = [ClipWindow](), last = -1.0
            for w in windows where w.start >= last - 1e-6 { chosen.append(w); last = w.end }
            return count > 0 ? Array(chosen.prefix(count)) : chosen
        }
        var chosen = [ClipWindow]()
        for w in windows.sorted(by: { $0.score > $1.score }) {
            if chosen.allSatisfy({ w.end <= $0.start + 1e-6 || w.start >= $0.end - 1e-6 }) {
                chosen.append(w)
                if count > 0 && chosen.count >= count { break }
            }
        }
        return chosen.sorted { $0.start < $1.start }
    }
}

public enum Timecode {
    public static func format(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }
    public static func short(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
