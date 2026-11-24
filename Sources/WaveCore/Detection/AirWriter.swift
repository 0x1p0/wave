import Foundation

/// Air letters: long, continuous hand movements ("drawings"), cut out of the stream and compared with letters
/// you taught Wave. Two speakers at the same height see left/right and toward/away but not up/down, so a drawn
/// "W" doesn't look like a W to Wave — it doesn't have to: matching is against *your own* earlier drawings of it.
public struct AirDrawing: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    /// The drawing resampled to `AirWriter.points` steps of (left tone, right tone) motion, each channel scaled
    /// to ±1, flattened [l0, r0, l1, r1, …].
    public var shape: [Float]

    public var duration: Double { end - start }
}

/// A letter (or any shape) you taught, with a few examples of how you draw it.
public struct AirLetter: Sendable, Equatable, Codable, Identifiable {
    public var id = UUID()
    public var name: String
    /// What to open: an app's bundle identifier and its name.
    public var appID: String
    public var appName: String
    public var examples: [[Float]]

    public init(name: String, appID: String, appName: String, examples: [[Float]] = []) {
        self.name = name
        self.appID = appID
        self.appName = appName
        self.examples = examples
    }
}

public enum AirWriterEvent: Sendable, Equatable {
    /// Movement has gone on long enough that this is probably a drawing, not a push or swipe (since `start`).
    case drawingStarted(start: Double)
    case drawn(AirDrawing)
    /// A movement reported as `drawingStarted` ended without being a drawing (too long, typing during it, …).
    case drawingAbandoned
}

public final class AirWriter {
    public static let points = 40

    /// Drawings last this long…
    public var minDuration = 0.8
    public var maxDuration = 4.0
    /// …and change direction at least this many times on one tone. (Duration is what sets a drawing apart from a
    /// push or swipe, which last under ~0.5 s; a circle is just toward-then-away on each tone.)
    public var minTurns = 1
    /// Quiet this long ends a drawing; shorter pauses (between strokes) don't.
    public var endQuiet = 0.35
    public var detector: DetectorConfig

    private var frames: [(t: Double, l: Float, r: Float)] = []
    private var lastMotion = -Double.infinity
    private var startedReported = false
    private var lastInput = -Double.infinity

    /// Keyboard/trackpad input: a drawing with typing in it isn't one.
    public func noteInput(at t: Double) { lastInput = max(lastInput, t) }

    public init(detector: DetectorConfig = DetectorConfig()) { self.detector = detector }

    public func reset() {
        frames = []
        startedReported = false
    }

    /// `bands`: this frame's features for the two tones (left, right). One event at most per frame.
    public func process(_ bands: [BandFeatures]) -> AirWriterEvent? {
        guard bands.count >= 2 else { return nil }
        let t = bands[0].time
        let on = detector.effectiveOnDB
        let moving = bands.contains { max($0.towardDB, $0.awayDB) >= on }
        // Signed motion per tone: toward minus away energy (dB), so its sign is the direction along that tone's path.
        func motion(_ f: BandFeatures) -> Float { max(-30, min(30, f.towardDB - f.awayDB)) * (max(f.towardDB, f.awayDB) >= detector.effectiveOffDB ? 1 : 0) }
        if moving {
            if frames.isEmpty || t - lastMotion > endQuiet { frames = []; startedReported = false }
            lastMotion = t
        }
        if !frames.isEmpty || moving {
            frames.append((t, motion(bands[0]), motion(bands[1])))
        }
        guard let first = frames.first else { return nil }
        let length = (moving ? t : lastMotion) - first.t
        if moving, !startedReported, length >= 0.7 {
            startedReported = true
            return .drawingStarted(start: first.t)
        }
        if moving {
            if length > maxDuration + 1 {
                let abandoned = startedReported
                frames = []; startedReported = false
                return abandoned ? .drawingAbandoned : nil
            }
            return nil
        }
        // Quiet: the drawing ends once it's been quiet long enough.
        guard t - lastMotion >= endQuiet else { return nil }
        let started = startedReported
        defer { frames = []; startedReported = false }
        let stroke = frames.filter { $0.t <= lastMotion }
        let typed = lastInput >= first.t - 0.5
        guard length >= minDuration, length <= maxDuration, turns(stroke) >= minTurns, !typed else {
            return started ? .drawingAbandoned : nil
        }
        return .drawn(AirDrawing(start: first.t, end: lastMotion, shape: Self.resample(stroke)))
    }

    /// Direction changes, counted on whichever tone moved more.
    private func turns(_ s: [(t: Double, l: Float, r: Float)]) -> Int {
        func count(_ v: [Float]) -> Int {
            var n = 0, last: Float = 0
            for x in v where abs(x) >= 3 {
                if last != 0 && (x > 0) != (last > 0) { n += 1 }
                last = x
            }
            return n
        }
        return max(count(s.map(\.l)), count(s.map(\.r)))
    }

    static func resample(_ s: [(t: Double, l: Float, r: Float)]) -> [Float] {
        guard s.count > 1 else { return [Float](repeating: 0, count: points * 2) }
        // Light smoothing, then even steps in time.
        func smooth(_ v: [Float]) -> [Float] {
            v.indices.map { i in
                let lo = max(0, i - 2), hi = min(v.count - 1, i + 2)
                return v[lo...hi].reduce(0, +) / Float(hi - lo + 1)
            }
        }
        let l = smooth(s.map(\.l)), r = smooth(s.map(\.r))
        let scale = max(1, (l + r).map(abs).max() ?? 1)
        var out: [Float] = []
        out.reserveCapacity(points * 2)
        for k in 0..<points {
            let x = Double(k) / Double(points - 1) * Double(s.count - 1)
            let i = Int(x), f = Float(x - Double(i)), j = min(i + 1, s.count - 1)
            out.append((l[i] * (1 - f) + l[j] * f) / scale)
            out.append((r[i] * (1 - f) + r[j] * f) / scale)
        }
        return out
    }

    /// Dynamic-time-warping distance between two shapes (lower is closer), per step.
    public static func distance(_ a: [Float], _ b: [Float]) -> Float {
        let n = a.count / 2, m = b.count / 2
        guard n > 0, m > 0 else { return .infinity }
        let band = max(4, n / 4)
        var prev = [Float](repeating: .infinity, count: m + 1), cur = prev
        prev[0] = 0
        for i in 1...n {
            cur = [Float](repeating: .infinity, count: m + 1)
            for j in max(1, i - band)...min(m, i + band) {
                let dl = a[2 * (i - 1)] - b[2 * (j - 1)], dr = a[2 * (i - 1) + 1] - b[2 * (j - 1) + 1]
                let cost = (dl * dl + dr * dr).squareRoot()
                cur[j] = cost + min(prev[j], cur[j - 1], prev[j - 1])
            }
            prev = cur
        }
        return prev[m] / Float(n + m)
    }

    /// The taught letter closest to `drawing`, if it's close enough and clearly closer than the runner-up.
    /// `score` 0…1 (1 = identical).
    public static func match(_ drawing: AirDrawing, in letters: [AirLetter], maxDistance: Float = 0.45)
        -> (letter: AirLetter, score: Float)? {
        let ranked = letters.compactMap { letter -> (AirLetter, Float)? in
            let d = letter.examples.map { distance(drawing.shape, $0) }.min()
            return d.map { (letter, $0) }
        }
        .sorted { $0.1 < $1.1 }
        guard let best = ranked.first, best.1 <= maxDistance else { return nil }
        if ranked.count > 1, best.1 > 0.85 * ranked[1].1 { return nil }  // too close to call
        return (best.0, max(0, 1 - best.1 / maxDistance))
    }
}
