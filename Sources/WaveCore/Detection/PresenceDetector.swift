import Foundation

/// Walk away / come back. Your body is a much bigger reflector than a hand: getting up and walking away is a
/// long, one-way "away" Doppler run (a swipe or a push turns around within ~0.2 s), and after it the room goes
/// still. Coming back is a long "toward" run, or touching the keyboard or trackpad.
public enum PresenceEvent: Sendable, Equatable {
    /// You got up and left: the departure, then an empty, still room for a while.
    case left
    /// You came back (moved in toward the screen, or typed / clicked).
    case returned
    /// A departure was seen; Wave is waiting to see whether the room stays empty (for the log and live views).
    case maybeLeaving
    /// …and it didn't (someone moved or typed): still here.
    case stillHere
}

public struct PresenceConfig: Sendable, Codable, Equatable {
    public var enabled = true
    /// A departure: away Doppler dominating continuously for at least this long (short gaps allowed).
    public var departureRun = 0.45
    /// Gaps up to this long don't break a run.
    public var runGap = 0.12
    /// After the departure, the room must stay still this long…
    public var emptyFor = 8.0
    /// …with no more than this fraction of frames showing motion above `stillDB` (people sitting still still
    /// shift and breathe; an empty room doesn't).
    public var emptyMaxActivity = 0.04
    public var stillDB: Float = 6
    /// Coming back: toward Doppler dominating continuously for at least this long.
    public var arrivalRun = 0.3

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        enabled = v(.enabled, enabled); departureRun = v(.departureRun, departureRun); runGap = v(.runGap, runGap)
        emptyFor = v(.emptyFor, emptyFor); emptyMaxActivity = v(.emptyMaxActivity, emptyMaxActivity)
        stillDB = v(.stillDB, stillDB); arrivalRun = v(.arrivalRun, arrivalRun)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, departureRun, runGap, emptyFor, emptyMaxActivity, stillDB, arrivalRun
    }
}

public final class PresenceDetector {
    public var config: PresenceConfig
    public var detector: DetectorConfig

    private enum State {
        case present
        /// Departed at `since`; counting frames and how many showed motion.
        case leaving(since: Double, frames: Int, active: Int)
        case away
    }

    private var state = State.present
    private var lastInput = -Double.infinity
    /// Continuous one-way runs being followed: start time and last frame that belonged to it.
    private var awayRun: (start: Double, last: Double)?
    private var towardRun: (start: Double, last: Double)?

    public init(config: PresenceConfig = PresenceConfig(), detector: DetectorConfig = DetectorConfig()) {
        self.config = config
        self.detector = detector
    }

    public var isAway: Bool { if case .away = state { return true } else { return false } }

    public func noteInput(at t: Double) { lastInput = max(lastInput, t) }

    /// The Mac was locked or put to sleep while away, and someone unlocked it: that's a return.
    public func reset(away: Bool = false) {
        state = away ? .away : .present
        awayRun = nil
        towardRun = nil
    }

    /// `f`: features of the strongest tone. Returns at most one event per frame.
    public func process(_ f: BandFeatures) -> PresenceEvent? {
        guard config.enabled else { return nil }
        let t = f.time
        let on = detector.effectiveOnDB
        let dominance = detector.dominanceDB
        let awayFrame = f.awayDB >= on && f.awayDB - f.towardDB >= dominance
        let towardFrame = f.towardDB >= on && f.towardDB - f.awayDB >= dominance
        let departed = follow(&awayRun, hit: awayFrame, at: t, needed: config.departureRun)
        let arrived = follow(&towardRun, hit: towardFrame, at: t, needed: config.arrivalRun)
        let typed = t - lastInput < 0.5

        switch state {
        case .present:
            if departed && !typed {
                state = .leaving(since: t, frames: 0, active: 0)
                return .maybeLeaving
            }
        case .leaving(let since, var frames, var active):
            frames += 1
            if max(f.towardDB, f.awayDB) >= config.stillDB { active += 1 }
            if typed || arrived {
                state = .present
                return .stillHere
            }
            if t - since >= config.emptyFor {
                if Double(active) <= config.emptyMaxActivity * Double(max(1, frames)) {
                    state = .away
                    return .left
                }
                state = .present
                return .stillHere
            }
            state = .leaving(since: since, frames: frames, active: active)
        case .away:
            if typed || arrived {
                state = .present
                return .returned
            }
        }
        return nil
    }

    /// Extends or ends a continuous run; true once it has lasted `needed` (reported once per run).
    private func follow(_ run: inout (start: Double, last: Double)?, hit: Bool, at t: Double, needed: Double) -> Bool {
        if hit {
            if let r = run, t - r.last <= config.runGap {
                let reached = t - r.start >= needed && r.last - r.start < needed
                run = (r.start, t)
                return reached
            }
            run = (t, t)
            return false
        }
        if let r = run, t - r.last > config.runGap { run = nil }
        return false
    }
}
