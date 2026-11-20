import Foundation

/// Deterministic test signals: pilot direct path, Doppler-shifted hand reflections and noise.
/// Used by unit tests now and by the detector tests in M1.
public enum SyntheticSignal {
    /// A steady sine.
    public static func tone(frequency: Double, amplitude: Float, sampleRate: Double, count: Int, phase: Double = 0) -> [Float] {
        let w = 2 * Double.pi * frequency / sampleRate
        return (0..<count).map { amplitude * Float(sin(phase + w * Double($0))) }
    }

    /// The pilot reflected off a hand moving with radial velocity `velocity(t)` (m/s, + = toward the laptop).
    /// The reflected frequency is f·(c+v)/(c−v) ≈ f·(1 + 2v/c); phase is integrated sample by sample.
    public static func reflection(
        pilot frequency: Double, amplitude: Float, sampleRate: Double, count: Int,
        velocity: (Double) -> Double
    ) -> [Float] {
        let c = PilotBand.speedOfSound
        var phase = 0.0
        var out = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let v = velocity(Double(n) / sampleRate)
            let f = frequency * (c + v) / (c - v)
            out[n] = amplitude * Float(sin(phase))
            phase += 2 * Double.pi * f / sampleRate
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
        return out
    }

    /// Velocity profile of a push: half-sine toward the laptop, a short stop, half-sine back.
    /// Positive = toward. Returns 0 outside the gesture.
    public static func pushVelocity(
        start: Double, toward: Double = 0.25, pause: Double = 0.05, away: Double = 0.25, peak: Double = 0.8
    ) -> @Sendable (Double) -> Double {
        { t in
            let x = t - start
            if x < 0 { return 0 }
            if x < toward { return peak * sin(Double.pi * x / toward) }
            let y = x - toward - pause
            if y < 0 { return 0 }
            if y < away { return -peak * sin(Double.pi * y / away) }
            return 0
        }
    }

    /// Gaussian white noise with the given RMS, from a fixed seed (reproducible).
    public static func noise(rms: Float, count: Int, seed: UInt64 = 0x5EED) -> [Float] {
        var state = seed &+ 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            // SplitMix64 → uniform (0, 1]
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return (Double(z >> 11) + 1) / Double(1 << 53)
        }
        var out = [Float](repeating: 0, count: count)
        var i = 0
        while i < count {
            // Box–Muller
            let r = (-2 * log(next())).squareRoot()
            let t = 2 * Double.pi * next()
            out[i] = rms * Float(r * cos(t))
            if i + 1 < count { out[i + 1] = rms * Float(r * sin(t)) }
            i += 2
        }
        return out
    }

    /// Element-wise sum of equal-length signals.
    public static func mix(_ signals: [Float]...) -> [Float] {
        guard let n = signals.map(\.count).min() else { return [] }
        var out = [Float](repeating: 0, count: n)
        for s in signals { for i in 0..<n { out[i] += s[i] } }
        return out
    }
}
