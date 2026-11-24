import Foundation

/// Hover controls (volume / brightness) and grab, built on what reliably shows up on real MacBooks: fast Doppler
/// motion (pushes and pulls) and, for grab, the short sharp sound of fingers closing onto the palm.
public struct InteractionConfig: Sendable, Codable, Equatable {
    public var dialEnabled = true
    public var grabEnabled = true
    /// Pull does something on its own (it's mapped to an action). When it isn't, pulls only count while hovering
    /// (pull = down); otherwise they'd claim motions that belong to swipes and do nothing with them.
    public var pullEnabled = true
    /// How many dial targets the app offers (holding still cycles through them).
    public var dialTargets = 2

    /// After bringing the hand up, holding really still for this long → ready ✋.
    public var holdDelay = 1.0
    /// "Really still": both sidebands below this (dB). A deliberately held hand measured ≤ 3.6 dB; ordinary
    /// fidgeting goes well past it.
    public var holdStillDB: Float = 5
    /// The arrival must be a real move: toward Doppler at least this many dB above the detector's minimum peak,
    /// lasting at least `approachMinDuration`. Twitches and reaching around used to switch hover on at random.
    public var approachMarginDB: Float = 2
    public var approachMinDuration = 0.1
    /// No keyboard/trackpad input for this long before the hand comes up (someone working isn't hovering).
    public var hoverInputQuiet = 2.0
    /// While ready, push = +step, pull = −step (fraction of the full range).
    public var dialStep: Double = 0.1
    /// Holding still this long switches to the next target; after the last one, the interaction ends.
    public var targetCycle = 3.0

    /// Grab: closing the hand makes a short "snap" (fingers meeting the palm) that lights up the whole
    /// ultrasonic band — measured at +12…+30 dB for ~40–90 ms. It must be at least this loud…
    public var grabSnapDB: Float = 12
    /// …and this short (a longer broadband rise is rustling or a bump, not a fist).
    public var grabMaxDuration = 0.15
    /// …and at least this much louder in the ultrasound than in the audible range (1–4 kHz). Fingers closing
    /// onto the palm are nearly silent to the ear (measured +7…+22 dB ultrasound over audible); a tap or knock
    /// on a table is loud to the ear too (−17…+4 dB).
    public var grabUltrasonicOverAudibleDB: Float = 6
    /// Opening the hand again snaps too: ignore snaps for this long after a grab (and 0.8 s after the last one).
    public var grabCooldown = 1.8
    /// Taps, knocks, typing and everyday movement snap too — on a real session they outnumbered fists 11 to 2.
    /// So a fist only counts while the hand is up and held still (✋ ready), which none of those reach.
    public var grabNeedsReady = true
    /// Typing and taps snap too. A grab needs no keyboard/trackpad input for this long before the snap…
    public var grabInputQuiet = 1.5
    /// …nor within this long after it (a palm landing on the laptop is followed by typing). This is also
    /// how long a grab takes to fire.
    public var grabDecisionDelay = 0.6

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        dialEnabled = v(.dialEnabled, dialEnabled); grabEnabled = v(.grabEnabled, grabEnabled)
        pullEnabled = v(.pullEnabled, pullEnabled)
        dialTargets = v(.dialTargets, dialTargets); holdDelay = v(.holdDelay, holdDelay)
        holdStillDB = v(.holdStillDB, holdStillDB); hoverInputQuiet = v(.hoverInputQuiet, hoverInputQuiet)
        grabInputQuiet = v(.grabInputQuiet, grabInputQuiet); grabDecisionDelay = v(.grabDecisionDelay, grabDecisionDelay)
        approachMarginDB = v(.approachMarginDB, approachMarginDB); approachMinDuration = v(.approachMinDuration, approachMinDuration)
        dialStep = v(.dialStep, dialStep); targetCycle = v(.targetCycle, targetCycle)
        grabSnapDB = v(.grabSnapDB, grabSnapDB); grabMaxDuration = v(.grabMaxDuration, grabMaxDuration)
        grabCooldown = v(.grabCooldown, grabCooldown)
        grabUltrasonicOverAudibleDB = v(.grabUltrasonicOverAudibleDB, grabUltrasonicOverAudibleDB)
        grabNeedsReady = v(.grabNeedsReady, grabNeedsReady)
    }

    private enum CodingKeys: String, CodingKey {
        case dialEnabled, grabEnabled, pullEnabled, dialTargets, holdDelay, holdStillDB, approachMarginDB, approachMinDuration, hoverInputQuiet
        case dialStep, targetCycle, grabSnapDB, grabMaxDuration, grabCooldown, grabInputQuiet, grabDecisionDelay
        case grabUltrasonicOverAudibleDB, grabNeedsReady
    }

    var anyEnabled: Bool { dialEnabled || grabEnabled }
}

/// Hover-control events.
public enum ControlEvent: Sendable, Equatable {
    /// Hand up and holding: Wave is ready (dial target index).
    case ready(target: Int)
    /// Held still longer: switched to another dial target.
    case targetChanged(Int)
    /// Turn the target up (+) or down (−) by this fraction of its range.
    case adjust(target: Int, delta: Double)
    /// Interaction over (hand withdrawn, typing, timeout, another gesture).
    case ended
}

/// Recognises "bring the hand up and hold it", then turns pushes into "up", pulls into "down" and pulling the
/// hand away into "done"; a swipe ends it and still switches desktops. Separately, recognises a grab from the
/// snap of a closing hand.
public final class InteractionDetector {
    public var config: InteractionConfig
    public var detector: DetectorConfig

    public enum Phase: String, Sendable { case idle, approaching, holding, ready, cooldown }

    private enum State {
        case idle
        case approaching(start: Double, last: Double, peak: Float, noisy: Bool)
        case settling(since: Double)
        case ready(cycleStart: Double, target: Int)
        case cooldown(until: Double)
    }

    private var state = State.idle
    private var lastInput = -Double.infinity
    private var lastTime: Double?
    private var firstTime: Double?

    // Grab (snap) tracking, independent of the hover state.
    private var snap: (start: Double, last: Double, peak: Float, toward: Float, away: Float, audible: Float, ready: Bool)?
    /// Finished snaps waiting a moment to make sure no keystroke came with them.
    private var pendingSnap: (start: Double, end: Double, peak: Float, toward: Float, away: Float)?
    private var snapsBlockedUntil = -Double.infinity

    public init(config: InteractionConfig = InteractionConfig(), detector: DetectorConfig = DetectorConfig()) {
        self.config = config
        self.detector = detector
    }

    public func noteInput(at t: Double) { lastInput = max(lastInput, t) }

    public func reset() {
        state = .idle
        snap = nil
        pendingSnap = nil
        lastTime = nil
        firstTime = nil
    }

    /// Where the interaction stands (for the tutorial's live view).
    public var phase: Phase {
        switch state {
        case .idle: return .idle
        case .approaching: return .approaching
        case .settling: return .holding
        case .ready: return .ready
        case .cooldown: return .cooldown
        }
    }

    public var isEngaged: Bool {
        if case .ready = state { return true }
        return false
    }

    /// While engaged, gesture events become controls: push → up, pull → down, pulling away → done; a swipe ends
    /// the hover and still happens. Returns nil when not engaged (the event acts as a normal gesture);
    /// `swallow` says whether the event is used up.
    public func consume(_ e: GestureEvent) -> (controls: [ControlEvent], swallow: Bool)? {
        guard config.dialEnabled, case .ready(_, let target) = state else { return nil }
        switch (e.kind, e.outcome) {
        case (.push, .accepted):
            state = .ready(cycleStart: e.end, target: target)
            return (config.dialEnabled ? [.adjust(target: target, delta: config.dialStep)] : [], true)
        case (.pull, .accepted):
            state = .ready(cycleStart: e.end, target: target)
            return (config.dialEnabled ? [.adjust(target: target, delta: -config.dialStep)] : [], true)
        case (.pull, .noReturn):
            // Moved away and didn't come back: finished.
            state = .cooldown(until: e.end + 0.5)
            return ([.ended], true)
        case (.swipeLeft, .accepted), (.swipeRight, .accepted), (.grab, .accepted):
            // Swipes stay swipes: a hand paused between swipes looks exactly like a hover.
            state = .cooldown(until: e.end + 0.3)
            return ([.ended], false)
        default:
            return ([], true)  // other candidates while hovering are swallowed
        }
    }

    /// `f`: features of the strongest tone.
    public func process(_ f: BandFeatures, pilotHz: Double) -> (controls: [ControlEvent], events: [GestureEvent]) {
        guard config.anyEnabled else { return ([], []) }
        var controls: [ControlEvent] = []
        var events: [GestureEvent] = []
        let t = f.time
        let dt = lastTime.map { t - $0 } ?? 0
        lastTime = t
        if firstTime == nil { firstTime = t }
        let warm = t - firstTime! >= detector.warmUp
        let on = detector.effectiveOnDB
        let off = detector.effectiveOffDB
        // A snap or click (broadband, as loud as the Doppler) is not a hand arriving.
        let noisy = f.referenceDB >= config.grabSnapDB
        let toward = f.towardDB >= on && f.velocity >= detector.minVelocity && f.towardDB - f.awayDB >= detector.dominanceDB
        let moving = f.towardDB >= on || f.awayDB >= on
        let typing = t - lastInput < detector.inputGuard

        func end(cooldown: Double) {
            controls.append(.ended)
            state = .cooldown(until: t + cooldown)
        }

        if config.grabEnabled, warm, let grab = trackSnap(f, frame: dt, pilotHz: pilotHz) {
            if isEngaged { end(cooldown: 1.0) }
            events.append(grab)
        }

        switch state {
        case .cooldown(let until):
            if t >= until { state = .idle }

        case .idle:
            let busy = t - lastInput < config.hoverInputQuiet
            let wantsHover = config.dialEnabled || (config.grabEnabled && config.grabNeedsReady)
            if wantsHover && !busy && toward && !noisy { state = .approaching(start: t, last: t, peak: f.towardDB, noisy: false) }

        case .approaching(let start, var last, var peak, var wasNoisy):
            wasNoisy = wasNoisy || noisy
            if f.towardDB >= off { last = t; peak = max(peak, f.towardDB) }
            if typing || f.awayDB >= on {
                state = .idle  // came straight back: a push, not a hover
            } else if f.towardDB < off {
                // Only a real arrival counts: strong enough, long enough, and not a snap or a click.
                let real = !wasNoisy && peak >= detector.effectiveMinPeakDB + config.approachMarginDB
                    && last - start >= config.approachMinDuration
                state = real ? .settling(since: t) : .idle
            } else if t - start > 1.5 {
                state = .idle
            } else {
                state = .approaching(start: start, last: last, peak: peak, noisy: wasNoisy)
            }

        case .settling(let since):
            if typing || max(f.towardDB, f.awayDB) >= config.holdStillDB {
                state = .idle
            } else if t - since >= config.holdDelay {
                state = .ready(cycleStart: t, target: 0)
                controls.append(.ready(target: 0))
            }

        case .ready(let cycleStart, let target):
            if typing {
                end(cooldown: 0.5)
            } else if !moving && t - cycleStart >= config.targetCycle {
                // Motion only postpones the switch (so it never lands mid-push); it doesn't restart the clock,
                // so a hover nobody meant to start ends by itself.
                let next = target + 1
                if config.dialEnabled && next < config.dialTargets {
                    controls.append(.targetChanged(next))
                    state = .ready(cycleStart: t, target: next)
                } else {
                    end(cooldown: 0.3)
                }
            }
        }
        return (controls, events)
    }

    /// Follows broadband bursts and returns a grab once a short one has passed with no keystroke around it.
    private func trackSnap(_ f: BandFeatures, frame: Double, pilotHz: Double) -> GestureEvent? {
        let t = f.time
        let level = config.grabSnapDB
        if f.referenceDB >= level && max(f.towardDB, f.awayDB) >= level {
            if var s = snap {
                s.last = t; s.peak = max(s.peak, f.referenceDB)
                s.toward = max(s.toward, f.towardDB); s.away = max(s.away, f.awayDB)
                s.audible = max(s.audible, f.audibleDB)
                snap = s
            } else {
                snap = (t, t, f.referenceDB, f.towardDB, f.awayDB, f.audibleDB, isEngaged)
            }
        } else if var s = snap {
            if f.referenceDB >= level - 6 && t - s.start <= 1 {
                s.last = t  // still ringing
                s.audible = max(s.audible, f.audibleDB)
                snap = s
            } else {
                snap = nil
                let end = s.last + max(frame, 0.005)
                let quietToTheEar = s.peak - s.audible >= config.grabUltrasonicOverAudibleDB
                let handUp = s.ready || !config.grabNeedsReady
                if end - s.start <= config.grabMaxDuration && quietToTheEar && handUp && s.start >= snapsBlockedUntil {
                    pendingSnap = (s.start, end, s.peak, s.toward, s.away)
                }
                // Any snap (a grab, the hand opening, flapping) holds off the next grab for a moment.
                snapsBlockedUntil = max(snapsBlockedUntil, end + 0.8)
            }
        }
        guard let p = pendingSnap, t >= p.end + config.grabDecisionDelay else { return nil }
        pendingSnap = nil
        // A keystroke or click shortly before or after it means it was the keyboard, the trackpad or a hand
        // landing on the laptop.
        guard lastInput < p.start - config.grabInputQuiet else { return nil }
        snapsBlockedUntil = max(snapsBlockedUntil, p.start + config.grabCooldown)
        return GestureEvent(
            kind: .grab, outcome: .accepted, pilotHz: pilotHz, start: p.start, end: p.end,
            confidence: Double(min(1, max(0.3, (p.peak - level) / 15 + 0.5))),
            towardPeakDB: p.toward, awayPeakDB: p.away, towardPeakVelocity: 0, awayPeakVelocity: 0,
            maxReferenceDB: p.peak, microPeakDB: p.peak)
    }
}
