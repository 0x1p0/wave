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

    // MARK: Stereo geometry

    /// Laptop geometry in metres: x → right, y ↑ above the keyboard, z → toward the user.
    /// Speakers sit in the hinge; the mic array near the middle.
    public struct Geometry: Sendable {
        public var leftSpeaker = SIMD3<Double>(-0.10, 0, 0)
        public var rightSpeaker = SIMD3<Double>(0.10, 0, 0)
        public var mic = SIMD3<Double>(-0.03, 0, 0.02)
        public init() {}

        public func path(from speaker: SIMD3<Double>, via hand: SIMD3<Double>) -> Double {
            let a = speaker - hand, b = hand - mic
            return (a * a).sum().squareRoot() + (b * b).sum().squareRoot()
        }
    }

    /// Two pilots (left speaker / right speaker) with the hand at `hand(t)`.
    public func renderStereo(
        left: Double, right: Double, geometry: Geometry = Geometry(), echoAmplitude: Float = 6e-5,
        hand: @escaping (Double) -> SIMD3<Double>
    ) -> [Float] {
        let binWidth = Self.sampleRate / 4096
        let fl = PilotBand(pilotHz: left, binWidth: binWidth).pilotHz
        let fr = PilotBand(pilotHz: right, binWidth: binWidth).pilotHz
        var x = SyntheticSignal.tone(frequency: fl, amplitude: pilotAmplitude, sampleRate: Self.sampleRate, count: count)
        let r = SyntheticSignal.tone(frequency: fr, amplitude: pilotAmplitude, sampleRate: Self.sampleRate, count: count, phase: 1)
        let noise = SyntheticSignal.noise(rms: noiseRMS, count: count, seed: seed)
        let el = SyntheticSignal.echo(pilot: fl, amplitude: echoAmplitude, sampleRate: Self.sampleRate, count: count) {
            geometry.path(from: geometry.leftSpeaker, via: hand($0))
        }
        let er = SyntheticSignal.echo(pilot: fr, amplitude: echoAmplitude, sampleRate: Self.sampleRate, count: count) {
            geometry.path(from: geometry.rightSpeaker, via: hand($0))
        }
        for i in 0..<count { x[i] += r[i] + noise[i] + el[i] + er[i] }
        return x
    }

    /// Hand resting in front of the laptop.
    public static let restingHand = SIMD3<Double>(0, 0.12, 0.40)

    /// Hand path for a push toward the screen centre starting at `start`.
    public static func pushPath(start: Double, depth: Double = 0.17, duration: Double = 0.55) -> (Double) -> SIMD3<Double> {
        { t in
            let u = (t - start) / duration
            guard u > 0, u < 1 else { return restingHand }
            let dz = depth * 0.5 * (1 - cos(2 * Double.pi * u))  // in and back out
            return SIMD3(restingHand.x, restingHand.y, restingHand.z - dz)
        }
    }

    /// Hand path for a horizontal swipe across the laptop (positive `speed` = left → right).
    public static func swipePath(start: Double, speed: Double = 1.0, height: Double = 0.12, distance: Double = 0.22,
                                 halfWidth: Double = 0.35) -> (Double) -> SIMD3<Double> {
        { t in
            let travel = 2 * halfWidth / abs(speed)
            let u = (t - start) / travel
            let from = speed > 0 ? -halfWidth : halfWidth
            if u <= 0 { return SIMD3(from, height, distance) }   // resting at the start side
            if u >= 1 { return SIMD3(-from, height, distance) }  // and at the far side afterwards
            return SIMD3(from + (speed > 0 ? 1 : -1) * 2 * halfWidth * u, height, distance)
        }
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
