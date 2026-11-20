import Foundation

/// Per-frame features for one pilot.
public struct BandFeatures: Sendable, Equatable, Codable {
    /// Seconds since the stream started (end of the analysis window).
    public var time: Double
    /// Pilot-bin power, dBFS.
    public var pilotDB: Float
    /// Energy above the pilot (motion toward the laptop) relative to the still-hand baseline, dB.
    public var towardDB: Float
    /// Energy below the pilot (motion away), dB over baseline.
    public var awayDB: Float
    /// Energy in the reference bands far from the pilot, dB over baseline (broadband-noise indicator).
    public var referenceDB: Float
    /// Doppler-centroid hand speed, m/s (+ toward). 0 when there is no clear motion.
    public var velocity: Float
    /// Motion (excess sideband) energy relative to the pilot, dB: how strong the reflection is.
    public var reflectionDB: Float
    /// Nothing is moving: all bands within 3 dB of baseline.
    public var quiet: Bool
    /// Phase tracker: changing-echo energy over its quiet level (dB) — sees slow/small motion.
    public var microDB: Float = 0
    /// Phase tracker: hand displacement toward the laptop during this frame (m).
    public var displacement: Float = 0
    /// Phase tracker: smoothed hand speed (m/s, + toward).
    public var basebandVelocity: Float = 0

    public init(time: Double, pilotDB: Float, towardDB: Float, awayDB: Float, referenceDB: Float,
                velocity: Float, reflectionDB: Float, quiet: Bool) {
        self.time = time
        self.pilotDB = pilotDB
        self.towardDB = towardDB
        self.awayDB = awayDB
        self.referenceDB = referenceDB
        self.velocity = velocity
        self.reflectionDB = reflectionDB
        self.quiet = quiet
    }
}

/// Extracts BandFeatures from power spectra, tracking a per-bin still-hand baseline.
///
/// Baseline: fast exponential average during warm-up; afterwards a ~1.5 s average that only updates
/// while the band is quiet, plus a ~20 s average otherwise (so a changed environment is eventually
/// absorbed even if it never looks quiet).
public final class FeatureExtractor {
    public let band: PilotBand
    public let referenceBins: ClosedRange<Int>
    public let referenceLower: Bool
    public let referenceUpper: Bool
    public let frameRate: Double
    public let warmUp: Double

    private let lo: Int
    private let hi: Int
    private var baseline: [Float]
    private var started = false
    private var warmUntil = 0.0
    private let alphaWarm: Float
    private let alphaQuiet: Float
    private let alphaSlow: Float

    public init(band: PilotBand, frameRate: Double, warmUp: Double = 0.6, referenceBins: ClosedRange<Int> = 40...60,
                referenceLower: Bool = true, referenceUpper: Bool = true) {
        precondition(referenceLower || referenceUpper)
        self.band = band
        self.referenceLower = referenceLower
        self.referenceUpper = referenceUpper
        self.frameRate = frameRate
        self.warmUp = warmUp
        self.referenceBins = referenceBins
        lo = band.pilotBin - max(band.outerBins, referenceBins.upperBound)
        hi = band.pilotBin + max(band.outerBins, referenceBins.upperBound)
        baseline = [Float](repeating: 0, count: hi - lo + 1)
        func alpha(_ tau: Double) -> Float { Float(1 - exp(-1 / (tau * frameRate))) }
        alphaWarm = alpha(0.1)
        alphaQuiet = alpha(1.5)
        alphaSlow = alpha(20)
    }

    /// Bins covered (pilot ± reference outer edge); the spectrum must contain them.
    public var binRange: ClosedRange<Int> { lo...hi }

    public func reset() { started = false }

    public func process(_ p: UnsafeBufferPointer<Float>, time: Double) -> BandFeatures {
        precondition(hi < p.count, "spectrum too short for pilot band")
        if !started {
            for k in lo...hi { baseline[k - lo] = p[k] }
            started = true
            warmUntil = time + warmUp
        }
        let kp = band.pilotBin
        @inline(__always) func base(_ k: Int) -> Float { max(baseline[k - lo], 1e-24) }

        var up: Float = 0, upBase: Float = 0, down: Float = 0, downBase: Float = 0
        var ref: Float = 0, refBase: Float = 0
        var excess: Float = 0, weighted: Float = 0, strongExcess: Float = 0
        for k in band.upperRange {
            up += p[k]; upBase += base(k)
            let x = p[k] - base(k)
            if x > 0 { excess += x }
            let s = p[k] - 3 * base(k)  // per-bin noise exceeds 3× its mean only ~5 % of the time
            if s > 0 { strongExcess += s; weighted += s * Float(k - kp) }
        }
        for k in band.lowerRange {
            down += p[k]; downBase += base(k)
            let x = p[k] - base(k)
            if x > 0 { excess += x }
            let s = p[k] - 3 * base(k)
            if s > 0 { strongExcess += s; weighted += s * Float(k - kp) }
        }
        for offset in referenceBins {
            if referenceLower { ref += p[kp - offset]; refBase += base(kp - offset) }
            if referenceUpper { ref += p[kp + offset]; refBase += base(kp + offset) }
        }

        let towardDB = (up / max(upBase, 1e-30)).dB
        let awayDB = (down / max(downBase, 1e-30)).dB
        let referenceDB = (ref / max(refBase, 1e-30)).dB
        let quiet = towardDB < 3 && awayDB < 3 && referenceDB < 3
        // Velocity only when the strong excess is a meaningful share of the sidebands (≥ ~3 dB overall).
        var velocity: Float = 0
        if strongExcess > 0.5 * (upBase + downBase) {
            velocity = Float(band.velocity(forBinOffset: Double(weighted / strongExcess)))
        }
        let features = BandFeatures(
            time: time, pilotDB: p[kp].dB, towardDB: towardDB, awayDB: awayDB, referenceDB: referenceDB,
            velocity: velocity, reflectionDB: excess > 0 ? (excess / max(p[kp], 1e-30)).dB : -120, quiet: quiet)

        // Baseline update.
        let alpha: Float = time < warmUntil ? alphaWarm : (quiet || (up < upBase && down < downBase) ? alphaQuiet : alphaSlow)
        for k in lo...hi {
            let i = k - lo
            baseline[i] += (p[k] - baseline[i]) * alpha
        }
        return features
    }
}
