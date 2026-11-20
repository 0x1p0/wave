import Foundation

/// The narrow band of FFT bins around one pilot tone.
///
///     |<-- lower sideband -->|  excluded  |<-- upper sideband -->|
///     pilot-outer … pilot-inner-1   pilot±(inner-1)   pilot+inner … pilot+outer
///
/// Hand moving *toward* the laptop shortens the reflection path → reflected tone shifts *up*.
public struct PilotBand: Sendable, Equatable {
    public static let speedOfSound = 343.0  // m/s at ~20 °C

    public let pilotHz: Double
    public let pilotBin: Int
    public let binWidth: Double
    /// Sidebands start this many bins from the pilot (the pilot's own Hann main lobe is ±1 bin
    /// for a bin-centred tone; 3 leaves one bin of margin).
    public let innerBins: Int
    /// Sidebands end this many bins from the pilot.
    public let outerBins: Int

    public init(pilotHz: Double, binWidth: Double, innerBins: Int = 3, outerBins: Int = 32) {
        self.pilotBin = Int((pilotHz / binWidth).rounded())
        self.pilotHz = Double(pilotBin) * binWidth
        self.binWidth = binWidth
        self.innerBins = innerBins
        self.outerBins = outerBins
    }

    public var sidebandBinCount: Int { outerBins - innerBins + 1 }
    public var upperRange: ClosedRange<Int> { (pilotBin + innerBins)...(pilotBin + outerBins) }
    public var lowerRange: ClosedRange<Int> { (pilotBin - outerBins)...(pilotBin - innerBins) }

    /// Doppler shift (Hz) → radial hand velocity (m/s, positive = toward). Reflection doubles the shift.
    public func velocity(forShift shiftHz: Double) -> Double {
        shiftHz * Self.speedOfSound / (2 * pilotHz)
    }

    public func velocity(forBinOffset offset: Double) -> Double { velocity(forShift: offset * binWidth) }

    /// Measures one spectrum frame.
    public func measure(_ spectrum: UnsafeBufferPointer<Float>) -> BandFrame {
        guard pilotBin + outerBins < spectrum.count, pilotBin - outerBins >= 0 else { return BandFrame() }
        var upper: Float = 0
        var lower: Float = 0
        var sidebandBins = [Float]()
        sidebandBins.reserveCapacity(2 * sidebandBinCount)
        for k in upperRange { upper += spectrum[k]; sidebandBins.append(spectrum[k]) }
        for k in lowerRange { lower += spectrum[k]; sidebandBins.append(spectrum[k]) }
        sidebandBins.sort()
        return BandFrame(
            pilotPower: spectrum[pilotBin],
            upperEnergy: upper,
            lowerEnergy: lower,
            sidebandMedian: sidebandBins[sidebandBins.count / 2])
    }

    public func measure(_ spectrum: [Float]) -> BandFrame {
        spectrum.withUnsafeBufferPointer { measure($0) }
    }
}

/// Per-frame measurements for one pilot (linear power, 1.0 = full-scale sine).
public struct BandFrame: Sendable, Equatable {
    /// Power in the pilot's own bin (the direct speaker→mic path plus static reflections).
    public var pilotPower: Float = 0
    /// Summed power above the pilot (positive Doppler: motion toward the laptop).
    public var upperEnergy: Float = 0
    /// Summed power below the pilot (negative Doppler: motion away).
    public var lowerEnergy: Float = 0
    /// Median per-bin power across both sidebands — a robust per-bin floor estimate.
    public var sidebandMedian: Float = 0

    public init(pilotPower: Float = 0, upperEnergy: Float = 0, lowerEnergy: Float = 0, sidebandMedian: Float = 0) {
        self.pilotPower = pilotPower
        self.upperEnergy = upperEnergy
        self.lowerEnergy = lowerEnergy
        self.sidebandMedian = sidebandMedian
    }
}

/// Small statistics helpers used by the probe and (later) calibration.
public enum Stats {
    public static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public static func mean(_ values: [Float]) -> Float {
        values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
    }

    /// Nearest-rank percentile, p in 0…1.
    public static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let idx = min(s.count - 1, max(0, Int((p * Double(s.count)).rounded(.up)) - 1))
        return s[idx]
    }
}
