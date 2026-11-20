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

    /// A reflecting part of the hand (palm, fingers) with time-varying strength and position.
    public struct Reflector {
        public var amplitude: (Double) -> Float
        public var position: (Double) -> SIMD3<Double>
        public init(amplitude: @escaping (Double) -> Float, position: @escaping (Double) -> SIMD3<Double>) {
            self.amplitude = amplitude
            self.position = position
        }
    }

    /// One tone on both speakers (modelled at the hinge centre) and any number of moving reflectors.
    public func renderSingle(pilotHz: Double = 19_000, reflectors: [Reflector], geometry: Geometry = Geometry()) -> [Float] {
        let f = PilotBand(pilotHz: pilotHz, binWidth: Self.sampleRate / 4096).pilotHz
        var x = SyntheticSignal.tone(frequency: f, amplitude: pilotAmplitude, sampleRate: Self.sampleRate, count: count)
        let noise = SyntheticSignal.noise(rms: noiseRMS, count: count, seed: seed)
        let speaker = SIMD3<Double>(0, 0, 0)
        let c = PilotBand.speedOfSound
        for n in 0..<count {
            let t = Double(n) / Self.sampleRate
            var v = noise[n]
            for r in reflectors {
                let length = geometry.path(from: speaker, via: r.position(t))
                var cycles = f * (t - length / c)
                cycles -= cycles.rounded(.down)
                let gain = Float(min(4, pow(0.5 / max(length, 0.05), 2)))
                v += r.amplitude(t) * gain * Float(sin(2 * Double.pi * cycles))
            }
            x[n] += v
        }
        return x
    }

    /// Smooth 0→1 ramp between `start` and `start + duration`.
    public static func ease(_ t: Double, start: Double, duration: Double) -> Double {
        let u = min(1, max(0, (t - start) / duration))
        return 0.5 - 0.5 * cos(Double.pi * u)
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

    /// 10 s hold demo: approach + hold (1.0 s), slide 5 cm closer (2.4–3.4 s, dial up), pull away (5.4 s),
    /// approach + hold again (6.5 s), close the hand (8.0 s, grab).
    public static func holdDemo() -> [Float] {
        let scene = SyntheticScene(duration: 10)
        let echo: Float = 6e-5
        func z(_ t: Double) -> Double {
            var z = 0.40 - 0.18 * ease(t, start: 1.0, duration: 0.35)        // approach
            z -= 0.05 * min(1, max(0, (t - 2.4) / 1.0))                       // slow slide closer
            z += 0.23 * ease(t, start: 5.4, duration: 0.3)                     // pull away
            z -= 0.18 * ease(t, start: 6.5, duration: 0.35)                    // approach again
            return z
        }
        let palm = Reflector(amplitude: { _ in echo }, position: { SIMD3(0, 0.12, z($0)) })
        let fingers = Reflector(
            amplitude: { t in t < 6.4 ? 0 : echo * Float(0.6 - 0.45 * ease(t, start: 8.0, duration: 0.25)) },
            position: { t in
                let u = ease(t, start: 8.0, duration: 0.25)
                return SIMD3(0, 0.19 - 0.05 * u, z(t) + 0.04 * u)
            })
        return scene.renderSingle(reflectors: [palm, fingers])
    }

    public static let demoScript = """
        1.5 s push · 3.5 s fast push · 5.5 s weak push · 7.0 s noise burst · 8.5 s one-way motion · \
        10.5 s push right after typing (10.2 s) · 12.3 s slower push
        """
}
