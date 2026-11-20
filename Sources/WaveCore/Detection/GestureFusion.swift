import Foundation

/// Which tones play where.
public enum PilotLayout: Sendable, Codable, Equatable, Hashable {
    /// One tone on both speakers: push only.
    case single(Double)
    /// One tone per speaker: push + swipe left/right (experimental).
    case stereo(left: Double, right: Double)

    public var frequencies: [Double] {
        switch self {
        case .single(let f): return [f]
        case .stereo(let l, let r): return [l, r]
        }
    }

    public var isStereo: Bool { if case .stereo = self { return true } else { return false } }

    /// Infers the layout from a list of pilots (1 → single, 2 → stereo, left first).
    public init(pilots: [Double]) {
        self = pilots.count >= 2 ? .stereo(left: pilots[0], right: pilots[1]) : .single(pilots.first ?? 19_000)
    }

    public var description: String {
        switch self {
        case .single(let f): return String(format: "%.2f kHz", f / 1000)
        case .stereo(let l, let r): return String(format: "L %.2f / R %.2f kHz", l / 1000, r / 1000)
        }
    }
}

/// Two-pilot gesture fusion settings.
public struct FusionConfig: Sendable, Codable, Equatable {
    /// Reversal-time difference below which both speakers saw the motion "at once": a push.
    public var minSwipeLag: Double = 0.045
    /// The two speakers' events must reverse within this of each other to be the same gesture.
    public var maxPairGap: Double = 0.5
    /// How long to wait for the other speaker before giving up on a one-sided event.
    public var pairTimeout: Double = 0.35
    /// Flip left/right (set by calibration if the speaker/mic geometry reverses the lag sign).
    public var invertSwipeDirection = false
    /// A push seen by only one tone still counts if both its phases peaked at least this high (dB).
    /// One tone per speaker is weaker than one tone on both, so requiring both lost real pushes.
    public var oneSidedPushDB: Float = 12

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Double.self, forKey: .minSwipeLag) { minSwipeLag = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .maxPairGap) { maxPairGap = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .pairTimeout) { pairTimeout = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .invertSwipeDirection) { invertSwipeDirection = v }
        if let v = try c.decodeIfPresent(Float.self, forKey: .oneSidedPushDB) { oneSidedPushDB = v }
    }

    private enum CodingKeys: String, CodingKey { case minSwipeLag, maxPairGap, pairTimeout, invertSwipeDirection, oneSidedPushDB }
}

/// Combines per-speaker push-shaped events (stereo layout) into push / swipe-left / swipe-right.
///
/// A hand moving across the laptop passes the left speaker's echo path before the right one's (or vice
/// versa), so each pilot sees toward→away, but at different times. A push toward the screen changes both
/// paths together. The lag between the two reversals decides.
public final class GestureFusion {
    public var config: FusionConfig
    private var pending: [Int: GestureEvent] = [:]

    public init(config: FusionConfig = FusionConfig()) { self.config = config }

    public func reset() { pending.removeAll() }

    /// `band` 0 = left speaker's pilot, 1 = right.
    public func add(_ event: GestureEvent, band: Int) -> [GestureEvent] {
        guard event.isAccepted else { return [event] }
        let other = 1 - band
        if let partner = pending[other], abs(reversal(event) - reversal(partner)) <= config.maxPairGap {
            pending[other] = nil
            let (left, right) = band == 0 ? (event, partner) : (partner, event)
            return [combine(left: left, right: right)]
        }
        var out: [GestureEvent] = []
        if let stale = pending[band] { out.append(oneSided(stale)) }
        pending[band] = event
        return out
    }

    /// Emits events whose partner never came.
    public func flush(now: Double) -> [GestureEvent] {
        var out: [GestureEvent] = []
        for (band, e) in pending where now - e.end > config.pairTimeout {
            pending[band] = nil
            out.append(oneSided(e))
        }
        return out
    }

    private func reversal(_ e: GestureEvent) -> Double { e.reversal ?? (e.start + e.end) / 2 }

    private func combine(left: GestureEvent, right: GestureEvent) -> GestureEvent {
        let lag = reversal(right) - reversal(left)  // > 0: left side first → hand moving left → right
        var e = left
        e.start = min(left.start, right.start)
        e.end = max(left.end, right.end)
        e.reversal = (reversal(left) + reversal(right)) / 2
        e.lag = lag
        e.towardPeakDB = max(left.towardPeakDB, right.towardPeakDB)
        e.awayPeakDB = max(left.awayPeakDB, right.awayPeakDB)
        e.towardPeakVelocity = (left.towardPeakVelocity + right.towardPeakVelocity) / 2
        e.awayPeakVelocity = (left.awayPeakVelocity + right.awayPeakVelocity) / 2
        e.maxReferenceDB = max(left.maxReferenceDB, right.maxReferenceDB)
        e.confidence = (left.confidence + right.confidence) / 2
        if abs(lag) < config.minSwipeLag {
            e.kind = .push
        } else {
            e.kind = (lag > 0) != config.invertSwipeDirection ? .swipeRight : .swipeLeft
            // Clearer separation from a push → more confident.
            e.confidence *= min(1, 0.6 + 0.4 * (abs(lag) / (3 * config.minSwipeLag)))
        }
        return e
    }

    private func oneSided(_ e: GestureEvent) -> GestureEvent {
        var r = e
        if min(e.towardPeakDB, e.awayPeakDB) >= config.oneSidedPushDB {
            r.kind = .push  // strong and clearly push-shaped: don't lose it because the other tone was weak
        } else {
            r.outcome = .oneSided
        }
        return r
    }
}
