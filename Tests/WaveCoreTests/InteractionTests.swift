import Foundation
import Testing
@testable import WaveCore

/// Hover controls (hand up and hold → push = up, pull = down, move away = done), pulls, grab, and the
/// one-motion-one-gesture rule, with a palm + fingers model in front of the laptop.
@Suite("Hover controls, pull and grab")
struct InteractionTests {
    static let palmEcho: Float = 6e-5
    let scene = SyntheticScene(duration: 8)

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

    func run(_ reflectors: [SyntheticScene.Reflector], inputs: [Double] = [],
             interaction: InteractionConfig = InteractionConfig()) -> (events: [GestureEvent], controls: [ControlEvent]) {
        let x = scene.renderSingle(reflectors: reflectors)
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
        // Up and hold (1.0 s); push at 2.3 s; pull at 3.6 s; move away for good at 5.0 s.
        let r = run([palm { t in
            Self.hoverZ(t) { t in
                Self.bump(t, start: 2.3, depth: 0.10) - Self.bump(t, start: 3.6, depth: 0.10)
                    - 0.25 * SyntheticScene.ease(t, start: 5.0, duration: 0.3)
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

    @Test func repeatedPushesAreNotPulls() {
        let r = run([palm { t in
            0.40 - Self.bump(t, start: 1.0, depth: 0.18, duration: 0.5) - Self.bump(t, start: 1.9, depth: 0.18, duration: 0.5)
                - Self.bump(t, start: 2.8, depth: 0.18, duration: 0.5)
        }])
        #expect(accepted(r.events, .push).count == 3)
        #expect(accepted(r.events, .pull).isEmpty)
    }

    @Test func holdingStillCyclesTargetsThenEnds() {
        let r = run([palm { Self.hoverZ($0) }])
        #expect(r.controls == [.ready(target: 0), .targetChanged(1), .ended])
    }

    @Test func typingCancelsHover() {
        let r = run([palm { t in Self.hoverZ(t) { t in Self.bump(t, start: 2.3, depth: 0.10) } }], inputs: [2.0])
        #expect(r.controls.contains(.ended))
        #expect(adjustments(r.controls).isEmpty)
    }

    @Test func closingTheRaisedHandIsAGrab() throws {
        // Fingers above the palm curl away from the screen and shrink at 2.6–2.85 s; the palm stays.
        var config = InteractionConfig()
        config.grabMicroDB = 12  // the synthetic room is quieter than a real hand's tremor
        let fingers = SyntheticScene.Reflector(
            amplitude: { t in Self.palmEcho * Float(1.0 - 0.8 * SyntheticScene.ease(t, start: 2.6, duration: 0.25)) },
            position: { t in
                let u = SyntheticScene.ease(t, start: 2.6, duration: 0.25)
                return SIMD3(0, 0.19 - 0.05 * u, Self.hoverZ(t) + 0.04 * u)
            })
        let r = run([palm { Self.hoverZ($0) }, fingers], interaction: config)
        let grabs = accepted(r.events, .grab)
        try #require(grabs.count == 1)
        #expect(grabs[0].start > 2.55 && grabs[0].end < 3.4)
        #expect(accepted(r.events, .push).isEmpty)
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
