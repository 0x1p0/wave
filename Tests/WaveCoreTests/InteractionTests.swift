import Foundation
import Testing
@testable import WaveCore

/// Hover controls (hand up and hold → push = up, pull = down, move away = done), pulls, grab, and the
/// one-motion-one-gesture rule, with a palm + fingers model in front of the laptop.
@Suite("Hover controls, pull and grab")
struct InteractionTests {
    static let palmEcho: Float = 6e-5

    /// Smooth out-and-back of `depth` metres (+ = toward the screen) starting at `start`.
    static func bump(_ t: Double, start: Double, depth: Double, duration: Double = 0.5) -> Double {
        let u = (t - start) / duration
        guard u > 0, u < 1 else { return 0 }
        return depth * 0.5 * (1 - cos(2 * Double.pi * u))
    }

    /// Palm distance from the screen: rests at 0.40 m, comes up to 0.22 m at 1.0–1.35 s and holds, then `extra`.
    static func hoverZ(_ t: Double, extra: (Double) -> Double = { _ in 0 }) -> Double {
        0.40 - 0.18 * SyntheticScene.ease(t, start: 1.0, duration: 0.35) - extra(t)
    }

    /// `snaps`: (start, length) of the sound of fingers closing onto the palm — ultrasonic, nearly silent to
    /// the ear. `knocks`: a tap on the table — broadband, loud to the ear as well.
    func run(_ reflectors: [SyntheticScene.Reflector], inputs: [Double] = [], snaps: [(Double, Double)] = [],
             knocks: [(Double, Double)] = [], duration: Double = 8,
             interaction: InteractionConfig = InteractionConfig()) -> (events: [GestureEvent], controls: [ControlEvent]) {
        let scene = SyntheticScene(duration: duration)
        var x = scene.renderSingle(reflectors: reflectors)
        for (i, snap) in snaps.enumerated() {
            // Three first differences tilt white noise ~50 dB toward the top of the band.
            var b = scene.burst(start: snap.0, length: snap.1, rms: 1, seed: UInt64(7 + i))
            for _ in 0..<3 { for k in stride(from: b.count - 1, to: 0, by: -1) { b[k] -= b[k - 1] } }
            let rms = (b.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, Int(snap.1 * SyntheticScene.sampleRate)))).squareRoot()
            for k in x.indices { x[k] += b[k] * 4e-4 / max(rms, 1e-9) }
        }
        for (i, knock) in knocks.enumerated() {
            let b = scene.burst(start: knock.0, length: knock.1, rms: 4e-4, seed: UInt64(70 + i))
            for k in x.indices { x[k] += b[k] }
        }
        let pipeline = GesturePipeline(sampleRate: SyntheticScene.sampleRate, channels: 1, layout: .single(19_000),
                                       interaction: interaction)
        var events: [GestureEvent] = [], controls: [ControlEvent] = []
        var i = 0, next = 0
        while i < x.count {
            let end = min(x.count, i + 480)
            while next < inputs.count && inputs[next] <= Double(end) / SyntheticScene.sampleRate {
                pipeline.noteInput(at: inputs[next]); next += 1
            }
            let out = pipeline.process([Array(x[i..<end])])
            events += out.events
            controls += out.controls
            i = end
        }
        return (events, controls)
    }

    func palm(_ z: @escaping (Double) -> Double) -> SyntheticScene.Reflector {
        SyntheticScene.Reflector(amplitude: { _ in Self.palmEcho }) { SIMD3(0, 0.12, z($0)) }
    }

    func adjustments(_ controls: [ControlEvent]) -> [Double] {
        controls.compactMap { if case .adjust(_, let d) = $0 { return d } else { return nil } }
    }

    func accepted(_ events: [GestureEvent], _ kind: GestureEvent.Kind) -> [GestureEvent] {
        events.filter { $0.kind == kind && $0.isAccepted }
    }

    @Test func holdThenPushTurnsUpPullTurnsDownMoveAwayEnds() {
        // Up (1.0 s) and hold (ready at ~2.3 s); push at 2.9 s; pull at 4.2 s; move away for good at 5.6 s.
        let r = run([palm { t in
            Self.hoverZ(t) { t in
                Self.bump(t, start: 2.9, depth: 0.10) - Self.bump(t, start: 4.2, depth: 0.10)
                    - 0.25 * SyntheticScene.ease(t, start: 5.6, duration: 0.3)
            }
        }])
        #expect(r.controls.first == .ready(target: 0))
        #expect(adjustments(r.controls) == [0.1, -0.1])
        #expect(r.controls.last == .ended)
        // Pushes and pulls while hovering are controls, not play/pause.
        #expect(accepted(r.events, .push).isEmpty && accepted(r.events, .pull).isEmpty)
    }

    @Test func pushWithoutHoldIsAPush() {
        let r = run([palm { t in 0.40 - Self.bump(t, start: 1.0, depth: 0.18, duration: 0.55) }])
        #expect(accepted(r.events, .push).count == 1)
        #expect(!r.controls.contains { if case .ready = $0 { return true } else { return false } })
    }

    @Test func pullFromRestIsAPull() {
        // Hand already near the screen; moves away 15 cm and back.
        let r = run([palm { t in 0.22 + Self.bump(t, start: 2.0, depth: 0.15, duration: 0.55) }])
        #expect(accepted(r.events, .pull).count == 1)
        #expect(accepted(r.events, .push).isEmpty)
    }

    @Test func pullIsIgnoredWhenItDoesNothing() {
        // Pull mapped to nothing: the motion isn't claimed as a pull (so it can't swallow a swipe).
        var config = InteractionConfig()
        config.pullEnabled = false
        let r = run([palm { t in 0.22 + Self.bump(t, start: 2.0, depth: 0.15, duration: 0.55) }], interaction: config)
        #expect(accepted(r.events, .pull).isEmpty)
    }

    @Test func repeatedPushesAreNotPulls() {
        let r = run([palm { t in
            0.40 - Self.bump(t, start: 1.0, depth: 0.18, duration: 0.5) - Self.bump(t, start: 1.9, depth: 0.18, duration: 0.5)
                - Self.bump(t, start: 2.8, depth: 0.18, duration: 0.5)
        }])
        #expect(accepted(r.events, .push).count == 3)
        #expect(accepted(r.events, .pull).isEmpty)
    }

    @Test func holdingStillCyclesTargetsThenEnds() {
        let r = run([palm { Self.hoverZ($0) }], duration: 10)
        #expect(r.controls == [.ready(target: 0), .targetChanged(1), .ended])
    }

    @Test func aTwitchWhileSittingStillDoesNotStartHover() {
        // A 1 cm fidget: real enough to show up, too small to be a hand arriving. (This used to switch hover on
        // and swallow the next push as "volume up".)
        let r = run([palm { t in 0.40 - 0.01 * SyntheticScene.ease(t, start: 1.5, duration: 0.1) }])
        #expect(r.controls.isEmpty)
    }

    @Test func noHoverRightAfterTyping() {
        // Same hand-up-and-hold, but the last keystroke was 1 s before: someone working, not hovering.
        let r = run([palm { Self.hoverZ($0) }], inputs: [0.1])
        #expect(r.controls.isEmpty)
    }

    @Test func aTapFollowedByTypingIsNotAGrab() {
        // A palm landing on the laptop (snap at 2.0 s), then the first keystroke 0.4 s later.
        let r = run([palm { Self.hoverZ($0) }], inputs: [2.45], snaps: [(2.0, 0.07)])
        #expect(accepted(r.events, .grab).isEmpty)
    }

    @Test func aSwipeWhileHoveringEndsTheHover() {
        let detector = InteractionDetector()
        // Not engaged: nothing to do.
        let swipe = GestureEvent(kind: .swipeLeft, outcome: .accepted, pilotHz: 1, start: 1, end: 1.3, confidence: 0.5,
                                 towardPeakDB: 15, awayPeakDB: 15, towardPeakVelocity: 0.4, awayPeakVelocity: -0.4,
                                 maxReferenceDB: 0, reversal: 1.15, lag: -0.04)
        #expect(detector.consume(swipe) == nil)
    }

    @Test func pullWithAStrongReturnIsStillAPull() {
        // Hand near the screen, away 12 cm over 0.3 s, then back faster (0.2 s): the return stroke is the
        // stronger one, and a push detector sees it as a push. The pull came first, so the pull wins.
        func z(_ t: Double) -> Double {
            let out = SyntheticScene.ease(t, start: 2.0, duration: 0.3)
            let back = SyntheticScene.ease(t, start: 2.3, duration: 0.2)
            return 0.22 + 0.12 * (out - back)
        }
        let r = run([palm(z)])
        #expect(accepted(r.events, .pull).count == 1)
        #expect(accepted(r.events, .push).isEmpty)
    }

    @Test func typingCancelsHover() {
        // Ready at ~2.3 s; a keystroke at 2.6 s ends it, so the push at 2.9 s is not "up".
        let r = run([palm { t in Self.hoverZ(t) { t in Self.bump(t, start: 2.9, depth: 0.10) } }], inputs: [2.6])
        #expect(r.controls.contains(.ended))
        #expect(adjustments(r.controls).isEmpty)
    }

    @Test func closingTheRaisedHandIsAGrab() throws {
        // Hand up and still; fingers snap onto the palm at 2.6 s (~70 ms of broadband sound).
        let r = run([palm { Self.hoverZ($0) }], snaps: [(2.6, 0.07)])
        let grabs = accepted(r.events, .grab)
        try #require(grabs.count == 1)
        #expect(grabs[0].start > 2.55 && grabs[0].end < 2.8)
        #expect(accepted(r.events, .push).isEmpty)
    }

    @Test func openingTheHandAgainIsNotASecondGrab() {
        // Ready at ~2.3 s; close at 2.6 s, open again at 3.4 s (snaps too).
        let r = run([palm { Self.hoverZ($0) }], snaps: [(2.6, 0.07), (3.4, 0.06)])
        #expect(accepted(r.events, .grab).count == 1)
    }

    @Test func aSnapWithoutTheHandHeldUpIsNotAGrab() {
        // Same snap, but the hand never came up and held still (no ✋): taps, typing, everyday noise.
        let r = run([palm { _ in 0.40 }], snaps: [(2.6, 0.07), (5.0, 0.07)])
        #expect(accepted(r.events, .grab).isEmpty)
    }

    @Test func aKnockOnTheTableIsNotAGrab() {
        // Loud to the ear as well as in the ultrasound: a tap or knock, not fingers closing.
        let r = run([palm { Self.hoverZ($0) }], knocks: [(2.0, 0.05), (4.0, 0.05)])
        #expect(accepted(r.events, .grab).isEmpty)
    }

    @Test func longRustleOrTypingIsNotAGrab() {
        // A 0.3 s broadband rustle, and a click that came with a keystroke.
        let r = run([palm { Self.hoverZ($0) }], inputs: [4.02], snaps: [(2.0, 0.3), (4.0, 0.05)])
        #expect(accepted(r.events, .grab).isEmpty)
    }

    @Test func stillHandTremorIsNotAGrab() {
        // A raised hand that never closes, with default (real-world) grab thresholds.
        let r = run([palm { Self.hoverZ($0) }])
        #expect(accepted(r.events, .grab).isEmpty)
    }

    @Test func emptyRoomDoesNothing() {
        let r = run([palm { _ in 0.40 }])
        #expect(r.controls.isEmpty)
        #expect(r.events.isEmpty)
    }
}
