import Foundation

/// One pilot sine wave and how loud it is on each speaker channel (0…1 relative gains).
public struct PilotTone: Sendable, Equatable {
    public var frequency: Double
    public var leftGain: Float
    public var rightGain: Float

    public init(frequency: Double, leftGain: Float = 1, rightGain: Float = 1) {
        self.frequency = frequency
        self.leftGain = leftGain
        self.rightGain = rightGain
    }
}

/// Fixed-size, allocation-free set of up to 4 tones, safe to hand to the audio thread.
public struct ToneSet: Sendable, Equatable {
    public static let capacity = 4
    public private(set) var count: Int = 0
    var frequency = SIMD4<Double>(repeating: 0)
    var left = SIMD4<Float>(repeating: 0)
    var right = SIMD4<Float>(repeating: 0)

    public static let silent = ToneSet([])

    public init(_ tones: [PilotTone]) {
        for (i, tone) in tones.prefix(Self.capacity).enumerated() {
            frequency[i] = tone.frequency
            left[i] = tone.leftGain
            right[i] = tone.rightGain
        }
        count = min(tones.count, Self.capacity)
    }

    public var tones: [PilotTone] {
        (0..<count).map { PilotTone(frequency: frequency[$0], leftGain: left[$0], rightGain: right[$0]) }
    }
}

/// Sine generator with click-free 50 ms raised-cosine fades on every start, stop and tone change.
/// Not thread-safe: owned by the audio render thread. Pure and allocation-free, so it is unit-testable.
public final class PilotSynth {
    public let sampleRate: Double
    public let fadeSeconds: Double

    private var current = ToneSet.silent      // what is sounding now
    private var requested = ToneSet.silent    // what we should be playing
    private var running = false
    private var phase = SIMD4<Double>(repeating: 0)
    private var envelope: Double = 0          // linear ramp position 0…1
    private let envelopeStep: Double
    private var amplitude: Float = 0          // smoothed output amplitude
    private var targetAmplitude: Float = 0
    private let amplitudeSmoothing: Float

    public init(sampleRate: Double, fadeSeconds: Double = 0.05) {
        self.sampleRate = sampleRate
        self.fadeSeconds = fadeSeconds
        envelopeStep = 1.0 / max(1, fadeSeconds * sampleRate)
        // One-pole smoothing (~15 ms) for amplitude changes while a tone is playing.
        amplitudeSmoothing = Float(1 - exp(-1 / (0.015 * sampleRate)))
    }

    /// True when nothing is audible (envelope fully closed).
    public var isSilent: Bool { envelope <= 0 }

    public func update(tones: ToneSet, amplitude: Float, running: Bool) {
        requested = tones
        targetAmplitude = amplitude
        self.running = running
        if envelope <= 0 { self.amplitude = amplitude }  // no need to glide while silent
    }

    /// Renders `frames` samples. `right` may be nil for mono output.
    public func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frames: Int) {
        let twoPi = 2 * Double.pi
        for n in 0..<frames {
            // Envelope: close when stopping or before switching tones; reopen once switched.
            let wantOpen = running && current == requested && current.count > 0
            if wantOpen {
                envelope = min(1, envelope + envelopeStep)
            } else if envelope > 0 {
                envelope = max(0, envelope - envelopeStep)
            }
            if envelope <= 0 && current != requested {
                current = requested
                phase = SIMD4<Double>(repeating: 0)
            }

            amplitude += (targetAmplitude - amplitude) * amplitudeSmoothing
            let shape = Float(0.5 - 0.5 * cos(Double.pi * envelope))
            let gain = amplitude * shape

            var l: Float = 0
            var r: Float = 0
            if gain > 0 {
                for i in 0..<current.count {
                    let s = Float(sin(phase[i]))
                    l += current.left[i] * s
                    r += current.right[i] * s
                }
            }
            left[n] = l * gain
            right?[n] = r * gain

            if current.count > 0 {
                phase += current.frequency * (twoPi / sampleRate)
                for i in 0..<current.count where phase[i] >= twoPi { phase[i] -= twoPi }
            }
        }
    }
}
