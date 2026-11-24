import Foundation
import Testing
@testable import WaveCore

/// Walk away / come back, with a body-sized reflector moving in front of the laptop.
@Suite("Walk away, come back")
struct PresenceTests {
    static let bodyEcho: Float = 2.5e-4

    func run(duration: Double, inputs: [Double] = [], body: @escaping (Double) -> Double) -> [PresenceEvent] {
        let scene = SyntheticScene(duration: duration)
        let reflector = SyntheticScene.Reflector(amplitude: { _ in Self.bodyEcho }) { SIMD3(0, 0.05, body($0)) }
        let x = scene.renderSingle(reflectors: [reflector])
        let pipeline = GesturePipeline(sampleRate: SyntheticScene.sampleRate, channels: 1, layout: .single(19_000))
        var events: [PresenceEvent] = []
        var i = 0, next = 0
        while i < x.count {
            let end = min(x.count, i + 480)
            while next < inputs.count && inputs[next] <= Double(end) / SyntheticScene.sampleRate {
                pipeline.noteInput(at: inputs[next]); next += 1
            }
            events += pipeline.process([Array(x[i..<end])]).presence
            i = end
        }
        return events
    }

    /// Sitting at 0.5 m, then getting up and walking away to 1.5 m over 1.2 s, starting at `start`.
    static func leave(_ t: Double, start: Double = 1.5) -> Double { 0.5 + 1.0 * SyntheticScene.ease(t, start: start, duration: 1.2) }

    @Test func walkingAwayAndStayingAwayIsLeaving() {
        let e = run(duration: 13) { Self.leave($0) }
        #expect(e == [.maybeLeaving, .left])
    }

    @Test func typingRightAfterMeansStillHere() {
        // Leaning back the same way, but typing 3 s later: not gone.
        let e = run(duration: 13, inputs: [5.5]) { Self.leave($0) }
        #expect(e == [.maybeLeaving, .stillHere])
    }

    @Test func comingBackIsAReturn() {
        let e = run(duration: 17) { t in Self.leave(t) - 1.0 * SyntheticScene.ease(t, start: 13.0, duration: 1.2) }
        #expect(e == [.maybeLeaving, .left, .returned])
    }

    @Test func pushesAndSwipesAreNotLeaving() {
        // A hand-sized push at 2 s: turns around within a fraction of a second.
        let e = run(duration: 13) { t in 0.5 - 0.15 * SyntheticScene.ease(t, start: 2, duration: 0.25)
            + 0.15 * SyntheticScene.ease(t, start: 2.3, duration: 0.25) }
        #expect(e.isEmpty)
    }
}
