import Foundation

/// A detected (or rejected) gesture candidate.
public struct GestureEvent: Sendable, Codable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case push
        case swipeLeft = "swipe left"
        case swipeRight = "swipe right"
        case grab
        /// Away from the screen and back (the mirror of a push).
        case pull
    }

    public enum Outcome: String, Sendable, Codable {
        case accepted
        case recentInput = "recent keyboard/trackpad input"
        case noiseBurst = "broadband noise"
        case tooFast = "too fast"
        case tooSlow = "too slow"
        case weak = "too weak"
        case noReturn = "no return movement"
        case oneSided = "seen by one speaker only"
        /// Two tones: no clear left/right timing, but too little motion toward the screen for a push.
        case sideways = "sideways, not a push"
        /// Push-shaped with no clear left/right timing, in the middle of a run of swipes: a swipe that passed the
        /// middle of the laptop, not a push.
        case duringSwipes = "during swipes, not a push"
        /// Two tones, one frame apart: not clearly a push (real pushes reach both in the same frame) and not
        /// clearly a swipe. Ignored rather than guessed.
        case unclear = "not clearly a push or a swipe"
    }

    public var id = UUID()
    public var kind: Kind
    public var outcome: Outcome
    public var pilotHz: Double
    /// Start of the toward phase and end of the away phase, seconds on the stream timeline.
    public var start: Double
    public var end: Double
    public var confidence: Double
    public var towardPeakDB: Float
    public var awayPeakDB: Float
    public var towardPeakVelocity: Float
    public var awayPeakVelocity: Float
    public var maxReferenceDB: Float
    /// When the motion turned from toward to away (start of the away phase).
    public var reversal: Double?
    /// Stereo layout: right-speaker reversal minus left-speaker reversal (s).
    public var lag: Double?
    /// Grab: peak micro-motion energy (dB over quiet).
    public var microPeakDB: Float?

    public var duration: Double { end - start }
    public var isAccepted: Bool { outcome == .accepted }

    /// One-line description, e.g. "PUSH ✓  conf 0.82  ▲+18.1 ▼+16.4 dB  0.46 s  v +0.71/−0.66 m/s".
    public var summary: String {
        let mark = isAccepted ? "✓" : "✗ \(outcome.rawValue)"
        var s = String(
            format: "%@ %@  conf %.2f  ▲%+.1f ▼%+.1f dB  %.2f s  v %+.2f/%+.2f m/s",
            kind.rawValue.uppercased(), mark, confidence, towardPeakDB, awayPeakDB, duration,
            towardPeakVelocity, awayPeakVelocity)
        if let lag { s += String(format: "  lag %+.0f ms", lag * 1000) }
        return s
    }
}

/// Recognises a push: a strong toward-the-screen Doppler phase followed promptly by a strong away phase,
/// within ~200–700 ms. Rejects slow drift, one-way motion, broadband noise and anything near recent
/// keyboard/trackpad input.
public final class PushDetector {
    public var config: DetectorConfig
    public let pilotHz: Double
    /// Mirror image: detects away → toward (a pull) instead of toward → away.
    public let mirrored: Bool

    /// `trailing`: the event already went out (early decision); follow the rest of the away phase exactly as if
    /// it hadn't, so the next candidate starts where it always would have.
    private enum Phase { case idle, toward, away, trailing }
    private var phase = Phase.idle
    private var towardStart = 0.0, towardLast = 0.0
    private var towardPeak: Float = 0, towardVelocity: Float = 0
    private var awayLast = 0.0
    private var awayStart = 0.0
    private var awayPeak: Float = 0, awayVelocity: Float = 0
    private var maxReference: Float = 0
    /// Last three frames' broadband level; their minimum is the "sustained" level.
    private var recentReference: [Float] = [0, 0, 0]
    private var sustainedReference: Float { recentReference.min()! }
    private var lastInput = -Double.infinity
    private var refractoryUntil = -Double.infinity
    private var trailingAccepted = false
    /// After any candidate ends, wait for both sidebands to calm down before starting a new one.
    private var waitForQuiet = false
    /// Detection starts `warmUp` after the first frame (and again after `reset()`).
    private var activeFrom: Double?

    public init(pilotHz: Double, config: DetectorConfig = DetectorConfig(), mirrored: Bool = false) {
        self.pilotHz = pilotHz
        self.config = config
        self.mirrored = mirrored
    }

    /// Records keyboard/trackpad input at stream time `t`.
    public func noteInput(at t: Double) { lastInput = max(lastInput, t) }

    public func reset() {
        phase = .idle
        activeFrom = nil
        waitForQuiet = false
        refractoryUntil = -Double.infinity
    }

    public func process(_ input: BandFeatures) -> GestureEvent? {
        var f = input
        if mirrored {
            swap(&f.towardDB, &f.awayDB)
            f.velocity = -f.velocity
        }
        let on = config.effectiveOnDB
        let off = config.effectiveOffDB
        recentReference.removeFirst()
        recentReference.append(f.referenceDB)
        if activeFrom == nil { activeFrom = f.time + config.warmUp }
        guard f.time >= activeFrom! else { return nil }
        if waitForQuiet {
            guard f.towardDB < off && f.awayDB < off else { return nil }
            waitForQuiet = false
        }

        switch phase {
        case .idle:
            guard f.time >= refractoryUntil else { return nil }
            if f.towardDB >= on && f.towardDB - f.awayDB >= config.dominanceDB && f.velocity >= config.minVelocity {
                phase = .toward
                towardStart = f.time; towardLast = f.time
                towardPeak = f.towardDB; towardVelocity = f.velocity
                maxReference = sustainedReference
                awayPeak = 0; awayVelocity = 0
            }
            return nil

        case .toward:
            maxReference = max(maxReference, sustainedReference)
            if f.awayDB >= on && f.awayDB - f.towardDB >= config.dominanceDB && f.velocity <= -config.minVelocity {
                phase = .away
                awayStart = f.time
                awayLast = f.time
                awayPeak = f.awayDB; awayVelocity = f.velocity
                return nil
            }
            if f.towardDB >= off && f.towardDB >= f.awayDB {
                towardLast = f.time
                towardPeak = max(towardPeak, f.towardDB)
                towardVelocity = max(towardVelocity, f.velocity)
            } else if f.time - towardLast > config.maxReversalGap {
                return abandon(.noReturn, end: towardLast)
            }
            if f.time - towardStart > config.maxDuration {
                return abandon(.tooSlow, end: f.time)
            }
            return nil

        case .trailing:
            if f.awayDB >= off && f.awayDB >= f.towardDB - 1 {
                awayLast = f.time
            } else if f.time - awayLast >= config.endHold || f.time - towardStart > config.maxDuration + 0.25 {
                phase = .idle
                waitForQuiet = true
                // The dead time after a gesture counts from where the movement really ended, as without the
                // early decision.
                if trailingAccepted { refractoryUntil = max(refractoryUntil, awayLast + config.refractory) }
            }
            return nil

        case .away:
            maxReference = max(maxReference, sustainedReference)
            if f.awayDB >= off && f.awayDB >= f.towardDB - 1 {
                awayLast = f.time
                awayPeak = max(awayPeak, f.awayDB)
                awayVelocity = min(awayVelocity, f.velocity)
            } else if f.time - awayLast >= config.endHold {
                return finish(end: awayLast)
            }
            // Early decision: the return is clearly happening; no need to wait for it to fade out.
            if config.earlyDecision > 0 && f.time - awayStart >= config.earlyDecision
                && awayPeak >= config.effectiveMinPeakDB && f.time - towardStart >= config.minDuration {
                let e = finish(end: f.time)
                phase = .trailing
                waitForQuiet = false
                trailingAccepted = e.isAccepted
                return e
            }
            if f.time - towardStart > config.maxDuration + 0.25 {
                return finish(end: f.time)
            }
            return nil
        }
    }

    // MARK: -

    /// A toward phase that never turned into a push. Reported only if it was strong (useful when tuning).
    private func abandon(_ outcome: GestureEvent.Outcome, end: Double) -> GestureEvent? {
        phase = .idle
        waitForQuiet = true
        guard towardPeak >= config.effectiveMinPeakDB else { return nil }
        return event(outcome, end: end, confidence: 0)
    }

    private func finish(end: Double) -> GestureEvent {
        phase = .idle
        waitForQuiet = true
        let duration = end - towardStart
        let outcome: GestureEvent.Outcome
        if lastInput >= towardStart - config.inputGuard {
            outcome = .recentInput
        } else if maxReference >= config.referenceRejectDB && maxReference > max(towardPeak, awayPeak) - config.referenceMarginDB {
            outcome = .noiseBurst
        } else if duration > config.maxDuration {
            outcome = .tooSlow
        } else if duration < config.minDuration {
            outcome = .tooFast
        } else if min(towardPeak, awayPeak) < config.effectiveMinPeakDB {
            outcome = .weak
        } else if mirrored && towardPeak < config.effectiveMinPeakDB + 2 {
            // A pull's first (away) stroke must be a real move, not the little dip people make before a push
            // (measured +11.2…+11.6 dB, against +12.7…+24.8 for real pulls). Whether the push that shares its
            // return stroke wins is decided by the pipeline, which sees both.
            outcome = .weak
        } else {
            outcome = .accepted
        }
        if outcome == .accepted { refractoryUntil = end + config.refractory }
        return event(outcome, end: end, confidence: confidence(duration: duration))
    }

    /// 0…1: strength above threshold × timing × toward/away balance × absence of broadband noise.
    private func confidence(duration: Double) -> Double {
        let margin = Double(min(towardPeak, awayPeak) - config.effectiveMinPeakDB)
        let strength = 1 / (1 + exp(-margin / 3))
        let mid = (config.minDuration + config.maxDuration) / 2
        let halfSpan = (config.maxDuration - config.minDuration) / 2
        let timing = 1 - 0.5 * min(1, abs(duration - mid) / halfSpan)
        let balance = 1 - min(0.5, Double(abs(towardPeak - awayPeak)) / 30)
        let noise = 1 - 0.5 * min(1, max(0, Double(maxReference / config.referenceRejectDB)))
        return min(1, max(0, strength * timing * balance * noise))
    }

    private func event(_ outcome: GestureEvent.Outcome, end: Double, confidence: Double) -> GestureEvent {
        if mirrored {
            // Report in physical terms: the first phase was away, the second toward.
            return GestureEvent(
                kind: .pull, outcome: outcome, pilotHz: pilotHz, start: towardStart, end: end,
                confidence: confidence, towardPeakDB: awayPeak, awayPeakDB: towardPeak,
                towardPeakVelocity: -awayVelocity, awayPeakVelocity: -towardVelocity, maxReferenceDB: maxReference,
                reversal: awayPeak > 0 ? awayStart : nil)
        }
        return GestureEvent(
            kind: .push, outcome: outcome, pilotHz: pilotHz, start: towardStart, end: end,
            confidence: confidence, towardPeakDB: towardPeak, awayPeakDB: awayPeak,
            towardPeakVelocity: towardVelocity, awayPeakVelocity: awayVelocity, maxReferenceDB: maxReference,
            reversal: awayPeak > 0 ? awayStart : nil)
    }
}
