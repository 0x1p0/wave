import Foundation
import Testing
@testable import WaveCore

/// Two pilots (left speaker 18.75 kHz, right 19.5 kHz) with a geometric hand model.
@Suite("Stereo: push vs swipes")
struct SwipeTests {
    static let layout = PilotLayout.stereo(left: 18_750, right: 19_250)

    func run(_ hand: @escaping (Double) -> SIMD3<Double>, duration: Double = 3.5, fusion: FusionConfig = FusionConfig()) -> [GestureEvent] {
        let scene = SyntheticScene(duration: duration)
        let x = scene.renderStereo(left: 18_750, right: 19_250, hand: hand)
        let pipeline = GesturePipeline(sampleRate: SyntheticScene.sampleRate, channels: 1, layout: Self.layout, fusion: fusion)
        var events: [GestureEvent] = []
        var i = 0
        while i < x.count {
            let end = min(x.count, i + 480)
            events += pipeline.process([Array(x[i..<end])]).events
            i = end
        }
        return events
    }

    @Test func stereoBandsDoNotOverlap() {
        let p = GesturePipeline(sampleRate: 48_000, channels: 1, layout: Self.layout)
        #expect(p.bands[0].upperRange.upperBound < p.bands[1].lowerRange.lowerBound)
    }

    @Test func stillHandProducesNothing() {
        #expect(run { _ in SyntheticScene.restingHand }.isEmpty)
    }

    @Test func pushIsAPush() throws {
        let accepted = run(SyntheticScene.pushPath(start: 1.5)).filter(\.isAccepted)
        try #require(accepted.count == 1)
        #expect(accepted[0].kind == .push)
        #expect(abs((accepted[0].lag ?? 1) - FusionConfig().lagCenter) < FusionConfig().minSwipeLag)
    }

    @Test func swipeLeftToRightIsSwipeRight() throws {
        let accepted = run(SyntheticScene.swipePath(start: 1.5, speed: 1.0)).filter(\.isAccepted)
        try #require(accepted.count == 1)
        #expect(accepted[0].kind == .swipeRight)
        #expect((accepted[0].lag ?? 0) > FusionConfig().lagCenter + FusionConfig().minSwipeLag)
    }

    @Test func swipeRightToLeftIsSwipeLeft() throws {
        let accepted = run(SyntheticScene.swipePath(start: 1.5, speed: -1.0)).filter(\.isAccepted)
        try #require(accepted.count == 1)
        #expect(accepted[0].kind == .swipeLeft)
    }

    @Test func inversionFlipsDirection() throws {
        var fusion = FusionConfig()
        fusion.invertSwipeDirection = true
        let accepted = run(SyntheticScene.swipePath(start: 1.5, speed: 1.0), fusion: fusion).filter(\.isAccepted)
        try #require(accepted.count == 1)
        #expect(accepted[0].kind == .swipeLeft)
    }

    @Test func fusionPairsAndTimesOut() {
        let fusion = GestureFusion()
        func e(_ rev: Double, peak: Float = 15) -> GestureEvent {
            GestureEvent(kind: .push, outcome: .accepted, pilotHz: 1, start: rev - 0.2, end: rev + 0.2, confidence: 0.8,
                         towardPeakDB: peak, awayPeakDB: peak, towardPeakVelocity: 0.8, awayPeakVelocity: -0.8,
                         maxReferenceDB: 0, reversal: rev)
        }
        #expect(fusion.add(e(1.00), band: 0).isEmpty)
        let swipe = fusion.add(e(1.12), band: 1)
        #expect(swipe.first?.kind == .swipeRight)
        // A strong push seen by one tone only still counts…
        #expect(fusion.add(e(2.0), band: 1).isEmpty)
        #expect(fusion.flush(now: 2.3).isEmpty)
        let strong = fusion.flush(now: 2.6)
        #expect(strong.first?.isAccepted == true && strong.first?.kind == .push)
        // …a weak one doesn't.
        #expect(fusion.add(e(4.0, peak: 8), band: 0).isEmpty)
        #expect(fusion.flush(now: 4.6).first?.outcome == .oneSided)
    }

    @Test func measuredLagsClassifyAsOnThisMac() {
        // Real MacBook data: right→left swipes −32…−43 ms, left→right +53…+75 ms, pushes near +10 ms.
        let c = FusionConfig()
        for lag in [-0.043, -0.032, -0.021] { #expect(c.classify(lag: lag, speed: 0.5) == .swipeLeft) }
        for lag in [0.053, 0.064, 0.075, 0.043] { #expect(c.classify(lag: lag, speed: 0.5) == .swipeRight) }
        for lag in [-0.010, 0.0, 0.010, 0.025] { #expect(c.classify(lag: lag, speed: 1.0) == .push) }
    }

    @Test func sidewaysMotionIsNotAPush() {
        // Half a swipe caught by one tone only, or both tones at once but barely moving toward the screen:
        // neither may play/pause.
        let fusion = GestureFusion()
        func e(_ rev: Double, speed: Float) -> GestureEvent {
            GestureEvent(kind: .push, outcome: .accepted, pilotHz: 1, start: rev - 0.2, end: rev + 0.2, confidence: 0.5,
                         towardPeakDB: 18, awayPeakDB: 18, towardPeakVelocity: speed, awayPeakVelocity: -speed,
                         maxReferenceDB: 0, reversal: rev)
        }
        #expect(fusion.add(e(1.0, speed: 0.4), band: 0).isEmpty)
        #expect(fusion.flush(now: 1.6).first?.outcome == .oneSided)
        #expect(fusion.add(e(3.0, speed: 0.4), band: 0).isEmpty)
        #expect(fusion.add(e(3.01, speed: 0.4), band: 1).first?.outcome == .sideways)
        // A real push (fast toward the screen) still counts either way.
        #expect(fusion.add(e(5.0, speed: 1.0), band: 0).isEmpty)
        #expect(fusion.flush(now: 5.6).first?.isAccepted == true)
    }

    @Test func swipeHalvesThatWereTooFastStillPair() {
        // Sideways motion gives each tone a short blip that alone is "too fast"; together they're a swipe.
        let fusion = GestureFusion()
        func e(_ rev: Double, _ outcome: GestureEvent.Outcome) -> GestureEvent {
            GestureEvent(kind: .push, outcome: outcome, pilotHz: 1, start: rev - 0.1, end: rev + 0.08, confidence: 0.3,
                         towardPeakDB: 15, awayPeakDB: 14, towardPeakVelocity: 0.5, awayPeakVelocity: -0.6,
                         maxReferenceDB: 0, reversal: rev)
        }
        #expect(fusion.add(e(1.00, .tooFast), band: 1).isEmpty)
        let swipe = fusion.add(e(1.04, .tooFast), band: 0)
        #expect(swipe.count == 1 && swipe[0].kind == .swipeLeft && swipe[0].isAccepted)
        // Two rejected halves at the same moment are not a push.
        #expect(fusion.add(e(3.00, .tooFast), band: 0).isEmpty)
        #expect(fusion.add(e(3.01, .tooFast), band: 1).allSatisfy { !$0.isAccepted })
    }
}
