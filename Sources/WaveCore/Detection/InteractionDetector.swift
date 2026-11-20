import Foundation

/// Hover controls (volume / brightness) and grab. Built on what reliably shows up on real MacBooks: fast
/// Doppler motion (pushes and pulls). Slow sliding turned out to sit too close to the noise to track.
public struct InteractionConfig: Sendable, Codable, Equatable {
    public var dialEnabled = true
    public var grabEnabled = true
    /// How many dial targets the app offers (holding still cycles through them).
    public var dialTargets = 2

    /// After bringing the hand up, no Doppler motion for this long = "holding" → ready ✋.
    public var holdDelay = 0.5
    /// While ready, push = +step, pull = −step (fraction of the full range).
    public var dialStep: Double = 0.1
    /// Holding still this long switches to the next target; after the last one, the interaction ends.
    public var targetCycle = 2.0

    /// Grab (experimental): a burst of micro-motion (fingers curling) at least this strong…
    public var grabMicroDB: Float = 18
    /// …and this far above the hand's own recent level (tremor and breathing already reach ~14 dB)…
    public var grabRiseDB: Float = 10
    /// …that fades (by `grabFadeDB`, for `grabFadeFrames`) within this time.
    public var grabMinDuration = 0.08
    public var grabMaxDuration = 0.7
    public var grabFadeDB: Float = 6
    public var grabFadeFrames = 8

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        dialEnabled = v(.dialEnabled, dialEnabled); grabEnabled = v(.grabEnabled, grabEnabled)
        dialTargets = v(.dialTargets, dialTargets); holdDelay = v(.holdDelay, holdDelay)
        dialStep = v(.dialStep, dialStep); targetCycle = v(.targetCycle, targetCycle)
        grabMicroDB = v(.grabMicroDB, grabMicroDB); grabRiseDB = v(.grabRiseDB, grabRiseDB)
        grabMinDuration = v(.grabMinDuration, grabMinDuration); grabMaxDuration = v(.grabMaxDuration, grabMaxDuration)
        grabFadeDB = v(.grabFadeDB, grabFadeDB); grabFadeFrames = v(.grabFadeFrames, grabFadeFrames)
    }

    private enum CodingKeys: String, CodingKey {
        case dialEnabled, grabEnabled, dialTargets, holdDelay, dialStep, targetCycle
        case grabMicroDB, grabRiseDB, grabMinDuration, grabMaxDuration, grabFadeDB, grabFadeFrames
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
    /// Interaction over (hand withdrawn, typing, timeout).
    case ended
}

/// Recognises "bring the hand up and hold it", then turns pushes into "up", pulls into "down", a grab into
/// a grab, and pulling the hand away into "done".
public final class InteractionDetector {
    public var config: InteractionConfig
    public var detector: DetectorConfig

    public enum Phase: String, Sendable { case idle, approaching, holding, ready, grabbing, cooldown }

    private enum State {
        case idle
        case approaching(start: Double)
        case settling(since: Double)
        case ready(cycleStart: Double, target: Int, microAvg: Float)
        case grabbing(start: Double, target: Int, peak: Float, avg: Float, fadeFrames: Int)
        case cooldown(until: Double)
    }

    private var state = State.idle
    private var lastInput = -Double.infinity

    public init(config: InteractionConfig = InteractionConfig(), detector: DetectorConfig = DetectorConfig()) {
        self.config = config
        self.detector = detector
    }

    public func noteInput(at t: Double) { lastInput = max(lastInput, t) }

    public func reset() { state = .idle }

    /// Where the interaction stands (for the tutorial's live view).
    public var phase: Phase {
        switch state {
        case .idle: return .idle
        case .approaching: return .approaching
        case .settling: return .holding
        case .ready: return .ready
        case .grabbing: return .grabbing
        case .cooldown: return .cooldown
        }
    }

    public var isEngaged: Bool {
        switch state {
        case .ready, .grabbing: return true
        default: return false
        }
    }

    /// While engaged, gesture events become controls: push → up, pull → down, pulling away → done.
    /// Returns nil when the event isn't consumed (it then acts as a normal gesture).
    public func consume(_ e: GestureEvent) -> [ControlEvent]? {
        let target: Int, avg: Float
        switch state {
        case .ready(_, let tg, let a): target = tg; avg = a
        case .grabbing(_, let tg, _, let a, _): target = tg; avg = a
        default: return nil
        }
        switch (e.kind, e.outcome) {
        case (.push, .accepted):
            state = .ready(cycleStart: e.end, target: target, microAvg: avg)
            return config.dialEnabled ? [.adjust(target: target, delta: config.dialStep)] : []
        case (.pull, .accepted):
            state = .ready(cycleStart: e.end, target: target, microAvg: avg)
            return config.dialEnabled ? [.adjust(target: target, delta: -config.dialStep)] : []
        case (.pull, .noReturn):
            // Moved away and didn't come back: finished.
            state = .cooldown(until: e.end + 0.5)
            return [.ended]
        default:
            return []  // other candidates while hovering are swallowed
        }
    }

    /// `f`: features of the strongest tone.
    public func process(_ f: BandFeatures, pilotHz: Double) -> (controls: [ControlEvent], events: [GestureEvent]) {
        guard config.anyEnabled else { return ([], []) }
        var controls: [ControlEvent] = []
        var events: [GestureEvent] = []
        let t = f.time
        let on = detector.effectiveOnDB
        let off = detector.effectiveOffDB
        let toward = f.towardDB >= on && f.velocity >= detector.minVelocity && f.towardDB - f.awayDB >= detector.dominanceDB
        let moving = f.towardDB >= on || f.awayDB >= on
        let typing = t - lastInput < detector.inputGuard

        func end(cooldown: Double) {
            controls.append(.ended)
            state = .cooldown(until: t + cooldown)
        }

        switch state {
        case .cooldown(let until):
            if t >= until { state = .idle }

        case .idle:
            if !typing && toward { state = .approaching(start: t) }

        case .approaching(let start):
            if typing || f.awayDB >= on {
                state = .idle  // came straight back: a push, not a hover
            } else if f.towardDB < off {
                state = .settling(since: t)
            } else if t - start > 1.5 {
                state = .idle
            }

        case .settling(let since):
            if typing || moving {
                state = .idle
            } else if t - since >= config.holdDelay {
                state = .ready(cycleStart: t, target: 0, microAvg: f.microDB)
                controls.append(.ready(target: 0))
            }

        case .ready(let cycleStart, let target, var avg):
            avg += (f.microDB - avg) * 0.05
            if typing {
                end(cooldown: 0.5)
            } else if config.grabEnabled && !moving && f.microDB >= config.grabMicroDB && f.microDB - avg >= config.grabRiseDB {
                state = .grabbing(start: t, target: target, peak: f.microDB, avg: avg, fadeFrames: 0)
            } else if moving {
                state = .ready(cycleStart: t, target: target, microAvg: avg)  // a push/pull is under way
            } else if t - cycleStart >= config.targetCycle {
                let next = target + 1
                if config.dialEnabled && next < config.dialTargets {
                    controls.append(.targetChanged(next))
                    state = .ready(cycleStart: t, target: next, microAvg: avg)
                } else {
                    end(cooldown: 0.3)
                }
            } else {
                state = .ready(cycleStart: cycleStart, target: target, microAvg: avg)
            }

        case .grabbing(let start, let target, let peak, let avg, var fadeFrames):
            let p = max(peak, f.microDB)
            fadeFrames = f.microDB < p - config.grabFadeDB ? fadeFrames + 1 : 0
            let duration = t - start
            if typing || moving {
                state = .ready(cycleStart: t, target: target, microAvg: avg)
            } else if fadeFrames >= config.grabFadeFrames {
                if duration >= config.grabMinDuration && duration <= config.grabMaxDuration + 0.1 {
                    events.append(GestureEvent(
                        kind: .grab, outcome: .accepted, pilotHz: pilotHz, start: start, end: t,
                        confidence: Double(min(1, max(0.3, (p - config.grabMicroDB) / 15 + 0.55))),
                        towardPeakDB: f.towardDB, awayPeakDB: f.awayDB, towardPeakVelocity: 0, awayPeakVelocity: 0,
                        maxReferenceDB: f.referenceDB, microPeakDB: p))
                    end(cooldown: 1.0)
                } else {
                    state = .ready(cycleStart: t, target: target, microAvg: avg)
                }
            } else if duration > config.grabMaxDuration + 0.4 {
                state = .ready(cycleStart: t, target: target, microAvg: avg)
            } else {
                state = .grabbing(start: start, target: target, peak: p, avg: avg, fadeFrames: fadeFrames)
            }
        }
        return (controls, events)
    }
}
