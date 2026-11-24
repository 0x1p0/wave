import Foundation
import Testing
@testable import WaveCore

/// Air letters with the two-tone geometric hand model: drawings are cut out, and a shape drawn again (a little
/// slower) matches the one taught, not a different shape.
@Suite("Air letters")
struct AirLetterTests {
    static let layout = PilotLayout.stereo(left: 18_750, right: 19_250)

    func drawings(_ hand: @escaping (Double) -> SIMD3<Double>, duration: Double = 5) -> [AirDrawing] {
        let scene = SyntheticScene(duration: duration)
        let x = scene.renderStereo(left: 18_750, right: 19_250, hand: hand)
        let pipeline = GesturePipeline(sampleRate: SyntheticScene.sampleRate, channels: 1, layout: Self.layout)
        var out: [AirDrawing] = []
        var i = 0
        while i < x.count {
            let end = min(x.count, i + 480)
            for e in pipeline.process([Array(x[i..<end])]).air { if case .drawn(let d) = e { out.append(d) } }
            i = end
        }
        return out
    }

    /// A zigzag across the laptop (three strokes) starting at 1.2 s, taking `seconds`.
    static func zigzag(seconds: Double) -> (Double) -> SIMD3<Double> {
        { t in
            let u = (t - 1.2) / seconds
            guard u > 0, u < 1 else { return SyntheticScene.restingHand }
            let x = 0.15 * sin(3 * Double.pi * u)
            return SIMD3(x, 0.12, 0.25 + 0.04 * u)
        }
    }

    /// A circle in the left/right × toward/away plane starting at 1.2 s, taking `seconds`.
    static func circle(seconds: Double) -> (Double) -> SIMD3<Double> {
        { t in
            let u = (t - 1.2) / seconds
            guard u > 0, u < 1 else { return SyntheticScene.restingHand }
            let a = 2 * Double.pi * u
            return SIMD3(0.14 * sin(a), 0.12, 0.26 + 0.14 * cos(a))  // starts and ends at the resting hand
        }
    }

    @Test func drawingsAreCutOut() {
        #expect(drawings(Self.zigzag(seconds: 1.6)).count == 1)
        #expect(drawings(Self.circle(seconds: 1.1)).count == 1)
    }

    @Test func aPushIsNotADrawing() {
        #expect(drawings(SyntheticScene.pushPath(start: 1.5)).isEmpty)
    }

    @Test func taughtShapesAreRecognisedWhenDrawnAgain() throws {
        let z = try #require(drawings(Self.zigzag(seconds: 1.6)).first)
        let o = try #require(drawings(Self.circle(seconds: 1.1)).first)
        let letters = [AirLetter(name: "Z", appID: "a", appName: "A", examples: [z.shape]),
                       AirLetter(name: "O", appID: "b", appName: "B", examples: [o.shape])]
        let z2 = try #require(drawings(Self.zigzag(seconds: 2.1)).first)
        let o2 = try #require(drawings(Self.circle(seconds: 1.4)).first)
        #expect(AirWriter.match(z2, in: letters)?.letter.name == "Z")
        #expect(AirWriter.match(o2, in: letters)?.letter.name == "O")
    }
}
