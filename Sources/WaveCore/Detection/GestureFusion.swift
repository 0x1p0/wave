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
    /// The lag a straight push produces (s). Measured with the camera on a MacBook: real pushes 0 ms; right→left
    /// swipes −11…−64 ms, left→right +21…+64 ms. Lags come in steps of one frame (10.7 ms).
    public var lagCenter: Double = 0
    /// Lag away from `lagCenter` beyond which the hand crossed the laptop: a swipe (two frames or more).
    public var minSwipeLag: Double = 0.016
    /// A one-frame lag also means a swipe when the hand barely moved toward the screen: pushes come at it
    /// (0.76–1.3 m/s measured), swipes mostly don't.
    public var softSwipeLag: Double = 0.008
    public var lateralSpeed: Float = 0.75
    /// A push comes at the screen: measured 0.76–1.25 m/s toward it, swipes 0.33–0.75. Two-tone motion with no
    /// clear left/right timing that is slower than this toward the screen is sideways, not a push (it was
    /// playing/pausing during swipes).
    public var minPushSpeed: Float = 0.55
    /// The two speakers' events must reverse within this of each other to be the same gesture.
    public var maxPairGap: Double = 0.15
    /// How long to wait for the other speaker before giving up on a one-sided event.
    public var pairTimeout: Double = 0.2
    /// Flip left/right (set by calibration if the speaker/mic geometry reverses the lag sign).
    public var invertSwipeDirection = false
    /// A push seen by only one tone still counts if both its phases peaked at least this high (dB).
    /// One tone per speaker is weaker than one tone on both, so requiring both lost real pushes.
    public var oneSidedPushDB: Float = 12
    /// A swipe whose per-tone halves were each "too fast" or "too weak" still counts if one tone's echo
    /// peaked at least this high (sideways motion gives short, weaker Doppler on each tone).
    public var swipeMinPeakDB: Float = 12
    /// A swipe only one tone reported still counts if that tone peaked this high and the other tone's echo shows
    /// it turning around (toward → away) a swipe-like time earlier or later. Weak swipes often reach only one tone.
    public var oneToneSwipeDB: Float = 10
    /// After a swipe, a push-shaped motion without a clear left/right timing is taken as part of the swiping
    /// (ignored) for this long; each such motion extends it. Measured: a run of back-and-forth swipes produced
    /// 4 'pushes' with 0 / ±11 ms timing, which played and paused the music.
    public var swipeStreak: Double = 2.5

    /// Which measured swipe/push window these values come from (2 = camera session, lag centre 0).
    public var windowVersion = 2

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        windowVersion = v(.windowVersion, 1)
        lagCenter = v(.lagCenter, lagCenter)
        minSwipeLag = v(.minSwipeLag, minSwipeLag)
        softSwipeLag = v(.softSwipeLag, softSwipeLag)
        lateralSpeed = v(.lateralSpeed, lateralSpeed)
        maxPairGap = v(.maxPairGap, maxPairGap)
        pairTimeout = v(.pairTimeout, pairTimeout)
        invertSwipeDirection = v(.invertSwipeDirection, invertSwipeDirection)
        oneSidedPushDB = v(.oneSidedPushDB, oneSidedPushDB)
        swipeMinPeakDB = v(.swipeMinPeakDB, swipeMinPeakDB)
        minPushSpeed = v(.minPushSpeed, minPushSpeed)
        oneToneSwipeDB = v(.oneToneSwipeDB, oneToneSwipeDB)
        swipeStreak = v(.swipeStreak, swipeStreak)
        // Settings saved before the camera-measured window (v2) used a wider cut-off that turned swipes into
        // pushes. Use the measured defaults instead.
        if windowVersion < 2 {
            let fresh = FusionConfig()
            lagCenter = fresh.lagCenter
            minSwipeLag = fresh.minSwipeLag
            softSwipeLag = fresh.softSwipeLag
            lateralSpeed = fresh.lateralSpeed
            windowVersion = 2
        }
    }

    private enum CodingKeys: String, CodingKey {
        case lagCenter, minSwipeLag, softSwipeLag, lateralSpeed, maxPairGap, pairTimeout, invertSwipeDirection, oneSidedPushDB, swipeMinPeakDB
        case minPushSpeed, oneToneSwipeDB, windowVersion, swipeStreak
    }

    /// What a lag (right reversal − left reversal) means for a motion with this radial speed.
    public func classify(lag: Double, speed: Float) -> GestureEvent.Kind {
        let offset = lag - lagCenter
        let sideways = abs(offset) >= minSwipeLag || (abs(offset) >= softSwipeLag && speed < lateralSpeed)
        guard sideways else { return .push }
        return (offset > 0) != invertSwipeDirection ? .swipeRight : .swipeLeft
    }
}

/// Combines per-speaker push-shaped events (stereo layout) into push / swipe-left / swipe-right.
///
/// A hand moving across the laptop passes the left speaker's echo path before the right one's (or vice
/// versa), so each pilot sees toward→away, but at different times. A push toward the screen changes both
/// paths together. The lag between the two reversals decides.
public final class GestureFusion {
    public var config: FusionConfig
    private var pending: [Int: GestureEvent] = [:]
    /// When the given tone's echo last turned from toward to away near a time (looser than a full event), if it
    /// did. Lets a swipe that only one tone reported still get its direction.
    public var reversalFinder: ((_ band: Int, _ around: Double) -> Double?)?

    public init(config: FusionConfig = FusionConfig()) { self.config = config }

    public func reset() { pending.removeAll() }

    /// Whether an event has the toward → away shape needed to time it against the other tone. Swipes pass each
    /// tone quickly and mostly sideways, so per-tone "too fast" / "too weak" halves still count here.
    private func pairable(_ e: GestureEvent) -> Bool {
        guard e.reversal != nil, e.kind == .push else { return false }
        switch e.outcome {
        case .accepted, .tooFast, .weak: return true
        default: return false
        }
    }

    /// `band` 0 = left speaker's pilot, 1 = right.
    public func add(_ event: GestureEvent, band: Int) -> [GestureEvent] {
        guard pairable(event) else { return [event] }
        let other = 1 - band
        if let partner = pending[other], abs(reversal(event) - reversal(partner)) <= config.maxPairGap {
            pending[other] = nil
            let (left, right) = band == 0 ? (event, partner) : (partner, event)
            if let combined = combine(left: left, right: right) { return [combined] }
            return [unpaired(left, band: 0), unpaired(right, band: 1)]
        }
        var out: [GestureEvent] = []
        if let stale = pending[band] { out.append(unpaired(stale, band: band)) }
        pending[band] = event
        return out
    }

    /// Emits events whose partner never came.
    public func flush(now: Double) -> [GestureEvent] {
        var out: [GestureEvent] = []
        for (band, e) in pending where now - e.end > config.pairTimeout {
            pending[band] = nil
            out.append(unpaired(e, band: band))
        }
        return out.sorted { $0.start < $1.start }
    }

    private func reversal(_ e: GestureEvent) -> Double { e.reversal ?? (e.start + e.end) / 2 }

    /// Nil when neither half is good enough for what the lag says it is.
    private func combine(left: GestureEvent, right: GestureEvent) -> GestureEvent? {
        let lag = reversal(right) - reversal(left)  // > 0: left side first → hand moving left → right
        let anyAccepted = left.isAccepted || right.isAccepted
        let speed = max(left.towardPeakVelocity, right.towardPeakVelocity)
        let kind = config.classify(lag: lag, speed: (left.towardPeakVelocity + right.towardPeakVelocity) / 2)
        var e = left.isAccepted || !right.isAccepted ? left : right
        e.kind = kind
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
        if kind == .push {
            guard anyAccepted else { return nil }
            e.outcome = speed >= config.minPushSpeed ? .accepted : .sideways
        } else {
            // Both tones saw a toward → away blip, one after the other: the hand crossed. Its echo just has to be clear.
            guard anyAccepted || (e.towardPeakDB >= config.swipeMinPeakDB && min(left.awayPeakDB, right.awayPeakDB) > 0) else { return nil }
            e.outcome = .accepted
            // Clearer separation from a push → more confident.
            let offset = abs(lag - config.lagCenter)
            e.confidence = max(e.confidence, 0.3) * min(1, 0.6 + 0.4 * (offset / (3 * config.minSwipeLag)))
        }
        return e
    }

    /// Only this tone produced an event: look at the other tone's echo for its turn-around. Both turn-arounds
    /// are measured the same (looser) way so the lag isn't biased by one tone's stricter event timing.
    private func oneToneSwipe(_ e: GestureEvent, band: Int) -> GestureEvent? {
        guard let finder = reversalFinder, max(e.towardPeakDB, e.awayPeakDB) >= config.oneToneSwipeDB,
              let theirs = finder(1 - band, reversal(e)) else { return nil }
        let mine = finder(band, reversal(e)) ?? reversal(e)
        let lag = band == 0 ? theirs - mine : mine - theirs
        guard abs(lag) <= config.maxPairGap else { return nil }
        let kind = config.classify(lag: lag, speed: e.towardPeakVelocity)
        guard kind != .push else { return nil }
        var r = e
        r.kind = kind
        r.lag = lag
        r.outcome = .accepted
        r.confidence = max(0.2, min(0.6, e.confidence))
        return r
    }

    private func unpaired(_ e: GestureEvent, band: Int) -> GestureEvent {
        if let swipe = oneToneSwipe(e, band: band) { return swipe }
        guard e.isAccepted else { return e }
        var r = e
        if min(e.towardPeakDB, e.awayPeakDB) >= config.oneSidedPushDB && e.towardPeakVelocity >= config.lateralSpeed {
            // Strong, clearly push-shaped and coming at the screen: don't lose it because the other tone was
            // weak. A slow one is far more likely half a swipe that only one tone caught.
            r.kind = .push
        } else {
            r.outcome = .oneSided
        }
        return r
    }
}
