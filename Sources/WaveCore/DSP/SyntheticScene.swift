import Foundation

/// A synthetic sonar scene at the levels measured in M0: 19 kHz pilot at −66 dBFS on a −120 dB/bin noise
/// floor, plus hand echoes with Doppler. A hand echo of 3.5e-5 (≈ −23 dB below the pilot) gives
/// ~+18 dB of sideband energy, like the real waving tests. Used by unit tests and `wave-probe synth`.
public struct SyntheticScene: Sendable {
    public static let sampleRate = 48_000.0
    public static let handEcho: Float = 3.5e-5

    public var duration: Double
    public var pilotHz: Double
    public var pilotAmplitude: Float = 5e-4
    public var noiseRMS: Float = 2.6e-5
    public var seed: UInt64 = 7

    public init(duration: Double = 4, pilotHz: Double = 19_000) {
        self.duration = duration
        self.pilotHz = PilotBand(pilotHz: pilotHz, binWidth: Self.sampleRate / 4096).pilotHz
    }

    public var count: Int { Int(duration * Self.sampleRate) }

    public struct Echo {
        public var amplitude: Float
        public var velocity: (Double) -> Double
        public init(amplitude: Float = SyntheticScene.handEcho, velocity: @escaping (Double) -> Double) {
            self.amplitude = amplitude
            self.velocity = velocity
        }
    }

    public func render(echoes: [Echo] = [], extra: [Float] = []) -> [Float] {
        var x = SyntheticSignal.tone(frequency: pilotHz, amplitude: pilotAmplitude, sampleRate: Self.sampleRate, count: count)
        let noise = SyntheticSignal.noise(rms: noiseRMS, count: count, seed: seed)
        for i in 0..<count { x[i] += noise[i] }
        for echo in echoes {
            let e = SyntheticSignal.reflection(
                pilot: pilotHz, amplitude: echo.amplitude, sampleRate: Self.sampleRate, count: count, velocity: echo.velocity)
            for i in 0..<count { x[i] += e[i] }
        }
        for i in 0..<min(count, extra.count) { x[i] += extra[i] }
        return x
    }

    /// White noise between `start` and `start + length` seconds (rustling, typing clicks…).
    public func burst(start: Double, length: Double, rms: Float, seed: UInt64 = 99) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let n = Int(length * Self.sampleRate)
        let noise = SyntheticSignal.noise(rms: rms, count: n, seed: seed)
        let s = Int(start * Self.sampleRate)
        for i in 0..<n where s + i < count && s + i >= 0 { out[s + i] = noise[i] }
        return out
    }

    /// A 14 s demo covering the interesting cases; times are in `demoScript`.
    public static func demo() -> (samples: [Float], inputTimes: [Double]) {
        let scene = SyntheticScene(duration: 14)
        let p1 = SyntheticSignal.pushVelocity(start: 1.5)
        let p2 = SyntheticSignal.pushVelocity(start: 3.5, toward: 0.15, pause: 0.03, away: 0.15, peak: 1.2)
        let weak = SyntheticSignal.pushVelocity(start: 5.5, peak: 0.6)
        let oneWay: @Sendable (Double) -> Double = { $0 > 8.5 && $0 < 9.7 ? 0.9 : 0 }
        let typed = SyntheticSignal.pushVelocity(start: 10.5)
        let p3 = SyntheticSignal.pushVelocity(start: 12.3, toward: 0.3, pause: 0.08, away: 0.3, peak: 0.7)
        let samples = scene.render(
            echoes: [
                Echo { p1($0) + p2($0) + oneWay($0) + typed($0) + p3($0) },
                Echo(amplitude: handEcho * 0.25) { weak($0) },
            ],
            extra: scene.burst(start: 7.0, length: 0.3, rms: 2.6e-4))
        return (samples, [10.2])
    }

    public static let demoScript = """
        1.5 s push · 3.5 s fast push · 5.5 s weak push · 7.0 s noise burst · 8.5 s one-way motion · \
        10.5 s push right after typing (10.2 s) · 12.3 s slower push
        """
}
