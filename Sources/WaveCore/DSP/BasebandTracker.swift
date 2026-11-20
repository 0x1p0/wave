import Foundation

/// Per-frame output of the baseband (phase) tracker.
public struct BasebandFrame: Sendable, Equatable {
    /// Energy of the *changing* part of the echo over its quiet level, dB. Sees slow and small motion
    /// (fingers curling, a hand sliding a few cm/s) that never leaves the pilot's own FFT bins.
    public var microDB: Float = 0
    /// Hand displacement toward the laptop during this frame, metres (negative = away).
    public var displacement: Float = 0
    /// Smoothed hand speed from the phase, m/s (+ toward).
    public var velocity: Float = 0
    /// Level of the static echo + direct path (dB re full scale).
    public var staticDB: Float = -120
}

/// Tracks the echo of one pilot at baseband, in the spirit of acoustic phase tracking (e.g. LLAP):
/// mix the pilot down to 0 Hz, low-pass, remove the slowly varying static vector (direct path + furniture),
/// and follow the phase of what's left. One full turn of phase = one wavelength of round-trip path
/// (1.8 cm at 19 kHz), so the hand's movement is resolved to millimetres even when it is far too slow
/// to show up as Doppler in the FFT.
public final class BasebandTracker {
    public let pilotHz: Double
    public let sampleRate: Double
    public static let outputRate = 500.0

    // Mixer
    private var phase = 0.0
    private let phaseStep: Double
    // Stage 1: boxcar → 2 kHz
    private let stage1: Int
    private var accI = 0.0, accQ = 0.0, accCount = 0
    // Stage 2: 4th-order Butterworth low-pass (100 Hz) at 2 kHz, then ÷4 → 500 Hz
    private var lpI: [Biquad]
    private var lpQ: [Biquad]
    private var stage2Count = 0
    // Static vector + quiet noise level
    private var staticI = 0.0, staticQ = 0.0
    private var staticReady = false
    private let staticAlpha: Double
    private var prevI = 0.0, prevQ = 0.0, havePrev = false
    private var prevAbove = false
    /// Quiet level of the dynamic-vector power, tracked in dB (≈ log-mean of the noise).
    private var noiseDB = -300.0
    private var samplesIn = 0
    private var warmSamples: Int
    private var velocity: Float = 0

    // Aggregation per analysis frame
    private struct Point { var index: Int; var displacement: Double; var power: Double; var staticPower: Double }
    private var points: [Point] = []

    public init(pilotHz: Double, sampleRate: Double) {
        self.pilotHz = pilotHz
        self.sampleRate = sampleRate
        phaseStep = 2 * Double.pi * pilotHz / sampleRate
        stage1 = max(1, Int((sampleRate / 2000).rounded()))
        let rate2 = sampleRate / Double(stage1)
        lpI = [Biquad.lowpass(fc: 100, fs: rate2, q: 0.5412), Biquad.lowpass(fc: 100, fs: rate2, q: 1.3066)]
        lpQ = lpI
        staticAlpha = 1 / (0.4 * Self.outputRate)  // τ = 0.4 s high-pass on the echo vector
        warmSamples = Int(0.5 * sampleRate)
    }

    public func reset() {
        staticReady = false
        havePrev = false
        noiseDB = -300
        prevAbove = false
        velocity = 0
        warmSamples = samplesIn + Int(0.5 * sampleRate)
        points.removeAll()
    }

    /// Feeds mono samples (the mean of the mic channels).
    public func process(_ x: UnsafeBufferPointer<Float>) {
        let decim2 = 4
        for v in x {
            let s = Double(v)
            accI += s * cos(phase)
            accQ -= s * sin(phase)
            phase += phaseStep
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            samplesIn += 1
            accCount += 1
            guard accCount == stage1 else { continue }
            var i = accI / Double(stage1), q = accQ / Double(stage1)
            accI = 0; accQ = 0; accCount = 0
            for k in 0..<lpI.count { i = lpI[k].process(i); q = lpQ[k].process(q) }
            stage2Count += 1
            guard stage2Count == decim2 else { continue }
            stage2Count = 0
            output(i: i, q: q)
        }
    }

    private func output(i: Double, q: Double) {
        if !staticReady {
            staticI = i; staticQ = q; staticReady = true
        }
        let warming = samplesIn < warmSamples
        let alpha = warming ? 20 * staticAlpha : staticAlpha
        staticI += (i - staticI) * alpha
        staticQ += (q - staticQ) * alpha
        let di = i - staticI, dq = q - staticQ
        let power = di * di + dq * dq

        // Quiet level, in dB so that sustained motion can't drag it up quickly: follows the noise when the
        // signal is near it (τ ≈ 0.5–1 s), creeps otherwise (τ ≈ 20 s).
        let powerDB = 10 * log10(max(power, 1e-30))
        if noiseDB < -299 { noiseDB = powerDB }
        let gap = powerDB - noiseDB
        noiseDB += gap * (gap < 0 ? 0.004 : gap < 5 ? 0.002 : 0.0001)

        // Phase steps only when the moving echo clearly stands out of the noise (12×, two samples in a
        // row); otherwise noise would add random ±4.5 mm jumps.
        let above = power > 12 * pow(10, noiseDB / 10)
        var displacement = 0.0
        if !warming && havePrev && above && prevAbove {
            // Phase advance of the dynamic vector: + means the path got shorter (hand toward).
            let cross = prevI * dq - prevQ * di
            let dot = prevI * di + prevQ * dq
            let dphi = atan2(cross, dot)
            // Round trip: path change = 2 × hand displacement.
            displacement = dphi * PilotBand.speedOfSound / (4 * Double.pi * pilotHz)
        }
        prevI = di; prevQ = dq; havePrev = true
        prevAbove = above
        points.append(Point(index: samplesIn, displacement: displacement, power: power,
                            staticPower: staticI * staticI + staticQ * staticQ))
    }

    /// Aggregates everything up to stream sample `index` (the analysis window's end).
    public func frame(endingAt index: Int, frameSeconds: Double) -> BasebandFrame {
        var disp = 0.0, power = 0.0, staticPower = 0.0, n = 0
        var consumed = 0
        for p in points where p.index <= index {
            disp += p.displacement
            power += p.power
            staticPower = p.staticPower
            n += 1
            consumed += 1
        }
        if consumed > 0 { points.removeFirst(consumed) }
        guard n > 0 else { return BasebandFrame(velocity: velocity) }
        let v = Float(disp / max(frameSeconds, 1e-3))
        velocity += (v - velocity) * 0.35
        let ratio = (power / Double(n)) / pow(10, noiseDB / 10)
        return BasebandFrame(
            microDB: samplesIn < warmSamples ? 0 : Float(10 * log10(max(ratio, 1e-6))),
            displacement: Float(disp), velocity: velocity,
            staticDB: Float(10 * log10(max(staticPower * 4, 1e-24))))
    }
}

/// Direct-form-I biquad.
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func lowpass(fc: Double, fs: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * fc / fs
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let a0 = 1 + alpha
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
