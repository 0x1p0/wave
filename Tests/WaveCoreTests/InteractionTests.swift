import Foundation
import Testing
@testable import WaveCore

/// Hold → dial / grab with a palm + fingers model in front of the laptop.
@Suite("Hold, dial and grab")
struct InteractionTests {
    static let palmEcho: Float = 6e-5
    let scene = SyntheticScene(duration: 6)

    /// Palm z (distance from the screen) over time: rests at 0.40 m, approaches to 0.22 m at 1.0–1.35 s,
    /// then whatever `after` does.
    static func palmZ(_ t: Double, after: (Double) -> Double = { _ in 0 }) -> Double {
        0.40 - 0.18 * SyntheticScene.ease(t, start: 1.0, duration: 0.35) - after(t)
    }

    func run(_ reflectors: [SyntheticScene.Reflector], inputs: [Double] = []) -> (events: [GestureEvent], controls: [ControlEvent]) {
        let x = scene.renderSingle(reflectors: reflectors)
        let pipeline = GesturePipeline(sampleRate: SyntheticScene.sampleRate, channels: 1, pilots: [19_000])
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

    func palm(_ z: @escaping (Double) -> Double, amplitude: @escaping (Double) -> Float = { _ in palmEcho }) -> SyntheticScene.Reflector {
        SyntheticScene.Reflector(amplitude: amplitude) { SIMD3(0, 0.12, z($0)) }
    }

    func adjustments(_ controls: [ControlEvent]) -> Double {
        controls.reduce(0) { sum, c in if case .adjust(_, let d) = c { return sum + d } else { return sum } }
    }

    @Test func holdThenSlowSlideTowardTurnsUp() {
        // Hold 1.35–2.4 s, then slide 5 cm closer at 5 cm/s, then hold until the dial ends.
        let r = run([palm { Self.palmZ($0) { t in 0.05 * min(1, max(0, (t - 2.4) / 1.0)) } }])
        #expect(r.controls.first == .ready(target: 0))
        #expect(r.controls.contains(.ended))
        let total = adjustments(r.controls)
        #expect(total > 0.08 && total < 0.3, "total adjustment \(total)")
        #expect(r.events.filter(\.isAccepted).isEmpty)
    }

    @Test func holdThenSlowSlideAwayTurnsDown() {
        let r = run([palm { Self.palmZ($0) { t in -0.05 * min(1, max(0, (t - 2.4) / 1.0)) } }])
        #expect(adjustments(r.controls) < -0.08)
        #expect(r.events.filter(\.isAccepted).isEmpty)
    }

    @Test func holdingStillCyclesTargetsThenEnds() {
        let r = run([palm { Self.palmZ($0) }])
        #expect(r.controls.first == .ready(target: 0))
        #expect(r.controls.contains(.targetChanged(1)))
        #expect(r.controls.last == .ended)
        #expect(abs(adjustments(r.controls)) < 0.01)
    }

    @Test func closingTheHandIsAGrab() throws {
        // Fingers above the palm curl away from the screen and shrink at 2.6–2.85 s; the palm stays.
        let fingers = SyntheticScene.Reflector(
            amplitude: { t in Self.palmEcho * Float(0.6 - 0.45 * SyntheticScene.ease(t, start: 2.6, duration: 0.25)) },
            position: { t in
                let u = SyntheticScene.ease(t, start: 2.6, duration: 0.25)
                return SIMD3(0, 0.19 - 0.05 * u, Self.palmZ(t) + 0.04 * u)
            })
        let r = run([palm { Self.palmZ($0) }, fingers])
        let grabs = r.events.filter { $0.kind == .grab && $0.isAccepted }
        try #require(grabs.count == 1)
        #expect(grabs[0].start > 2.55 && grabs[0].end < 3.3)
        #expect(abs(adjustments(r.controls)) < 0.02)
        #expect(!r.events.contains { $0.kind == .push && $0.isAccepted })
    }

    @Test func pushIsNotAHold() {
        // In and straight back out: a push, never "ready".
        let r = run([palm { t in 0.40 - 0.18 * sin(Double.pi * min(1, max(0, (t - 1.0) / 0.55))) }])
        #expect(r.events.contains { $0.kind == .push && $0.isAccepted })
        #expect(!r.controls.contains { if case .ready = $0 { return true } else { return false } })
    }

    @Test func pullingAwayEndsWithoutChangingTheLevel() {
        // Hold, then pull the hand away quickly (20 cm in 0.3 s).
        let r = run([palm { Self.palmZ($0) { t in -0.20 * SyntheticScene.ease(t, start: 2.3, duration: 0.3) } }])
        #expect(r.controls.first == .ready(target: 0))
        #expect(r.controls.contains(.ended))
        #expect(abs(adjustments(r.controls)) < 0.03)
        #expect(!r.events.contains { $0.kind == .grab && $0.isAccepted })
    }

    @Test func typingCancels() {
        // Same slide as the dial test, but with keyboard input during it.
        let r = run([palm { Self.palmZ($0) { t in 0.05 * min(1, max(0, (t - 2.4) / 1.0)) } }], inputs: [2.5])
        #expect(abs(adjustments(r.controls)) < 0.02)
    }

    @Test func emptyRoomDoesNothing() {
        let r = run([palm { _ in 0.40 }])
        #expect(r.controls.isEmpty)
        #expect(r.events.isEmpty)
    }
}
