import Foundation

/// Push-detector tuning. Energies are dB of sideband energy above the adaptive still-hand baseline.
/// Defaults come from the M0 measurements (waving at 19 kHz, −8 dBFS → +14…+17 dB).
public struct DetectorConfig: Sendable, Codable, Equatable {
    /// 0 = strict … 1 = sensitive. Shifts every energy threshold by up to ±6 dB around the defaults.
    public var sensitivity: Double = 0.5

    /// A phase (toward / away) starts when its sideband rises this far above baseline…
    public var onThresholdDB: Float = 8
    /// …and continues while it stays above this (hysteresis).
    public var offThresholdDB: Float = 4
    /// Both phases must peak at least this high for a push to count.
    public var minPeakDB: Float = 10
    /// The active side must exceed the other side by this much when a phase starts (rejects
    /// symmetric broadband rises such as fan noise or rustling).
    public var dominanceDB: Float = 3
    /// The Doppler centroid must agree with the phase direction by at least this speed (m/s).
    public var minVelocity: Float = 0.25

    /// Toward-start → away-end must take between these (seconds). Measured times include ~85 ms of
    /// FFT-window smear on top of the real motion.
    public var minDuration: Double = 0.2
    public var maxDuration: Double = 0.75
    /// Longest allowed lull between the end of "toward" and the start of "away".
    public var maxReversalGap: Double = 0.25
    /// The away phase ends after it has been below the off threshold this long.
    public var endHold: Double = 0.04

    /// Reject if the reference bands (far from the pilot, where hand Doppler can't reach) rise this much:
    /// that's broadband noise (clothing, rings, typing), not a reflection.
    public var referenceRejectDB: Float = 6
    /// …unless the Doppler sidebands stay this far above it. Both are measured as dB over their own still
    /// baselines, so flat noise (rustling, a fist's snap, clicks) raises them alike (measured −3.5…+5 dB apart),
    /// while a moving hand's Doppler towers over the little it spills out there (+5.7…+13 dB on real pulls).
    /// The broadband level counts only when it lasts 3 frames (~30 ms), so a single click inside a gesture
    /// doesn't sink it.
    public var referenceMarginDB: Float = 5.5
    /// Ignore gestures within this long after keyboard/trackpad input.
    public var inputGuard: Double = 0.8
    /// Dead time after an accepted push.
    public var refractory: Double = 0.4
    /// No detection until the baseline has settled.
    public var warmUp: Double = 0.6

    public init() {}

    // Tolerant decoding: settings files and recording sidecars from older versions keep working when
    // fields are added (missing keys fall back to defaults).
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Double.self, forKey: .sensitivity) { sensitivity = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .onThresholdDB) { onThresholdDB = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .offThresholdDB) { offThresholdDB = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .minPeakDB) { minPeakDB = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .dominanceDB) { dominanceDB = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .minVelocity) { minVelocity = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .minDuration) { minDuration = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .maxDuration) { maxDuration = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .maxReversalGap) { maxReversalGap = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .endHold) { endHold = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .referenceRejectDB) { referenceRejectDB = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .referenceMarginDB) { referenceMarginDB = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .inputGuard) { inputGuard = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .refractory) { refractory = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .warmUp) { warmUp = v }
    }

    private enum CodingKeys: String, CodingKey {
        case sensitivity, onThresholdDB, offThresholdDB, minPeakDB, dominanceDB, minVelocity, minDuration, maxDuration, maxReversalGap, endHold, referenceRejectDB, referenceMarginDB, inputGuard, refractory, warmUp
    }

    var sensitivityOffsetDB: Float { Float((0.5 - min(1, max(0, sensitivity))) * 12) }
    public var effectiveOnDB: Float { onThresholdDB + sensitivityOffsetDB }
    public var effectiveOffDB: Float { offThresholdDB + sensitivityOffsetDB }
    public var effectiveMinPeakDB: Float { minPeakDB + sensitivityOffsetDB }
}
