import Foundation

/// Hold / dial / grab tuning. Distances in metres, speeds in m/s, micro-motion in dB over its quiet level.
public struct InteractionConfig: Sendable, Codable, Equatable {
    public var dialEnabled = true
    public var grabEnabled = true
    /// How many dial targets the app offers (holding still cycles through them).
    public var dialTargets = 2

    /// Stillness needed after an approach before Wave shows "ready".
    public var holdDelay = 0.35
    /// Below this phase-tracked speed the hand counts as still.
    public var stillSpeed: Float = 0.04
    /// While ready and still, switch to the next dial target after this long; leave after the last one.
    public var targetCycle = 1.6
    /// Net movement before the dial starts (so a still hand doesn't nudge the level).
    public var deadZone: Float = 0.012
    /// Level change per metre of hand movement (5 → 5 % per cm). Toward the screen = up.
    public var dialGain: Float = 5
    /// Moving faster than this ends the dial (pulling the hand away).
    public var dialMaxSpeed: Float = 0.15
    /// Dial ends after this long without movement.
    public var dialIdleEnd = 1.5
    /// Adjustments are held back this long, so the fast pull-away that ends a dial can't nudge the level.
    public var dialDelay = 0.15

    /// Grab: closing the hand makes the moving part of the echo jump (fingers curl, the hand's echo shrinks)
    /// in a short *burst* that fades again, with little net movement. A slide keeps the echo moving.
    /// A burst must reach this micro-motion level…
    public var grabMicroDB: Float = 10
    /// …and rise this far above the level when "ready" began (so the fading echo of the approach can't fake it)…
    public var grabRiseDB: Float = 8
    /// …fade (by `grabFadeDB` from its peak) within this window…
    public var grabMinDuration = 0.08
    public var grabMaxDuration = 0.6
    public var grabFadeDB: Float = 6
    /// …with at most this much net hand movement, and this average net speed (a slide is ~4–5 cm/s).
    public var grabMaxDisplacement: Float = 0.015
    public var grabMaxNetSpeed: Float = 0.025
    /// Frames the burst must stay faded (one-frame dips during a slide don't count).
    public var grabFadeFrames = 8

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        dialEnabled = v(.dialEnabled, dialEnabled); grabEnabled = v(.grabEnabled, grabEnabled)
        dialTargets = v(.dialTargets, dialTargets); holdDelay = v(.holdDelay, holdDelay)
        stillSpeed = v(.stillSpeed, stillSpeed); targetCycle = v(.targetCycle, targetCycle)
        deadZone = v(.deadZone, deadZone); dialGain = v(.dialGain, dialGain); dialMaxSpeed = v(.dialMaxSpeed, dialMaxSpeed)
        dialIdleEnd = v(.dialIdleEnd, dialIdleEnd); dialDelay = v(.dialDelay, dialDelay)
        grabMicroDB = v(.grabMicroDB, grabMicroDB); grabMinDuration = v(.grabMinDuration, grabMinDuration)
        grabMaxDuration = v(.grabMaxDuration, grabMaxDuration); grabMaxDisplacement = v(.grabMaxDisplacement, grabMaxDisplacement)
        grabRiseDB = v(.grabRiseDB, grabRiseDB); grabFadeDB = v(.grabFadeDB, grabFadeDB)
        grabMaxNetSpeed = v(.grabMaxNetSpeed, grabMaxNetSpeed); grabFadeFrames = v(.grabFadeFrames, grabFadeFrames)
    }

    private enum CodingKeys: String, CodingKey {
        case dialEnabled, grabEnabled, dialTargets, holdDelay, stillSpeed, targetCycle, deadZone, dialGain, dialMaxSpeed
        case dialIdleEnd, dialDelay, grabMicroDB, grabMinDuration, grabMaxDuration, grabMaxDisplacement
        case grabRiseDB, grabFadeDB, grabMaxNetSpeed, grabFadeFrames
    }

    var anyEnabled: Bool { dialEnabled || grabEnabled }
}

/// Continuous-control events from the hold/dial interaction.
public enum ControlEvent: Sendable, Equatable {
    /// Hand raised and still: Wave is ready (dial target index).
    case ready(target: Int)
    /// Still longer: switched to another dial target.
    case targetChanged(Int)
    /// Turn the target up (+) or down (−) by this fraction of its range.
    case adjust(target: Int, delta: Double)
    /// Interaction over (hand withdrawn, idle, typing…).
    case ended
}

/// Recognises "approach and hold" and what follows: sliding closer/farther (dial) or closing the hand
/// (grab). Runs alongside the push detector, which handles quick toward→away motions.
public final class InteractionDetector {
    public var config: InteractionConfig
    public var detector: DetectorConfig

    private enum State {
        case idle
        case approaching(start: Double)
        case settling(since: Double, stillSince: Double?)
        case ready(since: Double, cycleStart: Double, target: Int, net: Float, floor: Float)
        /// Something moved while ready: grab (short burst that fades) or the start of a slide.
        case burst(start: Double, target: Int, net: Float, peak: Float, floor: Float, readySince: Double, fadeFrames: Int)
        case dialing(target: Int, lastMove: Double)
        case cooldown(until: Double)
    }

    private var state = State.idle
    private var lastInput = -Double.infinity
    private var pending: [(time: Double, delta: Double, target: Int)] = []

    public init(config: InteractionConfig = InteractionConfig(), detector: DetectorConfig = DetectorConfig()) {
        self.config = config
        self.detector = detector
    }

    public func noteInput(at t: Double) { lastInput = max(lastInput, t) }

    public func reset() {
        state = .idle
        pending.removeAll()
    }

    public var isEngaged: Bool {
        switch state {
        case .ready, .burst, .dialing: return true
        default: return false
        }
    }

    /// `f` combines all pilots (strongest sideband energy, mean displacement).
    public func process(_ f: BandFeatures, pilotHz: Double) -> (controls: [ControlEvent], events: [GestureEvent]) {
        guard config.anyEnabled else { return ([], []) }
        var controls: [ControlEvent] = []
        var events: [GestureEvent] = []
        let t = f.time
        let on = detector.effectiveOnDB
        let off = detector.effectiveOffDB
        let fastToward = f.towardDB >= on && f.velocity >= detector.minVelocity
        let fastAway = f.awayDB >= on && f.velocity <= -detector.minVelocity
        let still = abs(f.basebandVelocity) < config.stillSpeed && f.towardDB < off && f.awayDB < off
        let typing = t - lastInput < detector.inputGuard

        func end(cooldown: Double) {
            pending.removeAll()
            controls.append(.ended)
            state = .cooldown(until: t + cooldown)
        }

        switch state {
        case .cooldown(let until):
            if t >= until { state = .idle }

        case .idle:
            if !typing && fastToward && f.towardDB - f.awayDB >= detector.dominanceDB {
                state = .approaching(start: t)
            }

        case .approaching(let start):
            if fastAway || typing {
                state = .idle  // a push (or reaching for the keyboard), not a hold
            } else if f.towardDB < off {
                state = .settling(since: t, stillSince: still ? t : nil)
            } else if t - start > 1.5 {
                state = .idle
            }

        case .settling(let since, let stillSince):
            if fastAway || fastToward || typing {
                state = .idle
            } else if still {
                let s = stillSince ?? t
                if t - s >= config.holdDelay {
                    state = .ready(since: t, cycleStart: t, target: 0, net: 0, floor: f.microDB)
                    controls.append(.ready(target: 0))
                } else {
                    state = .settling(since: since, stillSince: s)
                }
            } else {
                state = .settling(since: since, stillSince: nil)
                if t - since > 1.2 { state = .idle }
            }

        case .ready(let since, let cycleStart, let target, var net, var floor):
            floor = min(floor, f.microDB)  // the quietest the moving echo has been since "ready"
            net += f.displacement
            if typing || fastAway || fastToward {
                end(cooldown: 0.5)
            } else if (f.microDB >= config.grabMicroDB && f.microDB - floor >= config.grabRiseDB)
                        || (config.dialEnabled && abs(net) > config.deadZone) {
                state = .burst(start: t, target: target, net: net, peak: f.microDB, floor: floor, readySince: since, fadeFrames: 0)
            } else if t - cycleStart >= config.targetCycle {
                let next = target + 1
                if config.dialEnabled && next < config.dialTargets {
                    controls.append(.targetChanged(next))
                    state = .ready(since: since, cycleStart: t, target: next, net: 0, floor: floor)
                } else {
                    end(cooldown: 0.3)
                }
            } else {
                state = .ready(since: since, cycleStart: cycleStart, target: target, net: net, floor: floor)
            }

        case .burst(let start, let target, var net, let peak, let floor, let readySince, var fadeFrames):
            net += f.displacement
            let p = max(peak, f.microDB)
            let duration = t - start
            fadeFrames = f.microDB < max(config.grabMicroDB - 3, p - config.grabFadeDB) ? fadeFrames + 1 : 0
            let faded = fadeFrames >= config.grabFadeFrames
            func startDial() {
                let excess = abs(net) > config.deadZone ? net - (net > 0 ? config.deadZone : -config.deadZone) : 0
                queue(Double(excess * config.dialGain), target: target, at: t)
                state = .dialing(target: target, lastMove: t)
            }
            if typing || fastAway || fastToward || abs(f.basebandVelocity) > config.dialMaxSpeed {
                end(cooldown: 0.5)
            } else if faded && duration <= config.grabMaxDuration + 0.1 {
                if config.grabEnabled && duration >= config.grabMinDuration && abs(net) <= config.grabMaxDisplacement
                    && abs(net) / Float(max(duration, 0.05)) <= config.grabMaxNetSpeed
                    && p >= config.grabMicroDB && p - floor >= config.grabRiseDB {
                    events.append(GestureEvent(
                        kind: .grab, outcome: .accepted, pilotHz: pilotHz, start: start, end: t,
                        confidence: Double(min(1, max(0.3, (p - config.grabMicroDB) / 15 + 0.55))),
                        towardPeakDB: f.towardDB, awayPeakDB: f.awayDB, towardPeakVelocity: 0, awayPeakVelocity: 0,
                        maxReferenceDB: f.referenceDB, microPeakDB: p))
                    end(cooldown: 1.0)
                } else if config.dialEnabled && abs(net) > config.deadZone {
                    startDial()  // a quick little slide
                } else {
                    state = .ready(since: readySince, cycleStart: t, target: target, net: 0, floor: f.microDB)
                }
            } else if duration > config.grabMaxDuration + 0.1 {
                // Still moving: a slide.
                if config.dialEnabled && abs(net) > config.deadZone {
                    startDial()
                } else if faded || abs(f.basebandVelocity) < config.stillSpeed {
                    state = .ready(since: readySince, cycleStart: t, target: target, net: net, floor: f.microDB)
                } else {
                    state = .burst(start: start, target: target, net: net, peak: p, floor: floor, readySince: readySince,
                                   fadeFrames: fadeFrames)
                }
            } else {
                state = .burst(start: start, target: target, net: net, peak: p, floor: floor, readySince: readySince,
                               fadeFrames: fadeFrames)
            }

        case .dialing(let target, let lastMove):
            if typing || fastAway || fastToward || abs(f.basebandVelocity) > config.dialMaxSpeed {
                end(cooldown: 0.6)  // drops the held-back adjustments
            } else {
                var moved = lastMove
                if abs(f.displacement) > 0 {
                    queue(Double(f.displacement * config.dialGain), target: target, at: t)
                    if abs(f.basebandVelocity) >= config.stillSpeed { moved = t }
                }
                if t - moved >= config.dialIdleEnd {
                    controls += pending.map { .adjust(target: $0.target, delta: $0.delta) }
                    pending.removeAll()
                    controls.append(.ended)
                    state = .cooldown(until: t + 0.3)
                } else {
                    state = .dialing(target: target, lastMove: moved)
                }
            }
        }

        // Release held-back adjustments.
        while let first = pending.first, t - first.time >= config.dialDelay {
            controls.append(.adjust(target: first.target, delta: first.delta))
            pending.removeFirst()
        }
        return (merge(controls), events)
    }

    private func queue(_ delta: Double, target: Int, at t: Double) {
        guard delta != 0 else { return }
        pending.append((t, delta, target))
    }

    /// Coalesce consecutive adjustments of the same target.
    private func merge(_ controls: [ControlEvent]) -> [ControlEvent] {
        var out: [ControlEvent] = []
        for c in controls {
            if case .adjust(let tg, let d) = c, case .adjust(let tg0, let d0)? = out.last, tg == tg0 {
                out[out.count - 1] = .adjust(target: tg, delta: d0 + d)
            } else {
                out.append(c)
            }
        }
        return out
    }
}
