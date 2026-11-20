import Foundation
import Testing
@testable import WaveCore

@Suite("Calibration")
struct CalibrationTests {
    let scene = Scene()

    /// Quiet frames + push examples collected with the permissive config → profile that accepts pushes
    /// and still ignores a quiet scene.
    @Test func calibratedThresholdsSeparatePushesFromStillness() throws {
        let quiet = scene.detect(scene.render()).frames.filter { $0.time > 1 }
        let noise = Calibrator.noiseLevel(quiet)
        #expect(noise > 0 && noise < 8)

        let collection = Calibrator.collectionDetector(noiseDB: noise)
        let v1 = SyntheticSignal.pushVelocity(start: 1.0, peak: 0.7)
        let v2 = SyntheticSignal.pushVelocity(start: 2.2, peak: 1.0)
        let examples = scene.render(echoes: [(Scene.handEcho, { v1($0) + v2($0) })])
        let pushes = scene.detect(examples, config: collection).events.filter(\.isAccepted)
        try #require(pushes.count == 2)

        let profile = Calibrator.makeProfile(layout: .single(19_000), quiet: quiet, pushes: pushes)
        #expect(profile.detector.onThresholdDB >= noise + 2 - 0.01)
        #expect(profile.detector.minPeakDB < pushes.map { min($0.towardPeakDB, $0.awayPeakDB) }.min()!)
        #expect(profile.pushPeaksDB.count == 2)

        #expect(scene.detect(examples, config: profile.detector).events.filter(\.isAccepted).count == 2)
        #expect(scene.detect(scene.render(), config: profile.detector).events.isEmpty)
    }

    @Test func swipeDirectionIsLearned() {
        func swipe(_ lag: Double) -> GestureEvent {
            GestureEvent(kind: .swipeRight, outcome: .accepted, pilotHz: 0, start: 0, end: 0.5, confidence: 1,
                         towardPeakDB: 15, awayPeakDB: 15, towardPeakVelocity: 1, awayPeakVelocity: -1,
                         maxReferenceDB: 0, reversal: 0.25, lag: lag)
        }
        let normal = Calibrator.makeProfile(
            layout: .stereo(left: 18_750, right: 19_500), quiet: [], pushes: [swipe(0.005), swipe(-0.01)],
            swipesLeft: [swipe(-0.09), swipe(-0.08)], swipesRight: [swipe(0.1), swipe(0.07)])
        #expect(!normal.fusion.invertSwipeDirection)
        #expect(normal.fusion.minSwipeLag > 0.01 && normal.fusion.minSwipeLag < 0.07)

        let mirrored = Calibrator.makeProfile(
            layout: .stereo(left: 18_750, right: 19_500), quiet: [], pushes: [],
            swipesLeft: [swipe(0.09)], swipesRight: [swipe(-0.1)])
        #expect(mirrored.fusion.invertSwipeDirection)
    }

    @Test func profileSurvivesJSON() throws {
        let profile = CalibrationProfile(layout: .stereo(left: 18_750, right: 19_500), detector: DetectorConfig(),
                                         fusion: FusionConfig(), noiseDB: 4.2)
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(CalibrationProfile.self, from: data) == profile)
    }
}

@Suite("Labeled samples")
struct SampleTests {
    @Test func windowsAndExport() throws {
        let scene = Scene()
        let x = scene.render(echoes: [(Scene.handEcho, SyntheticSignal.pushVelocity(start: 1.5))])
        let (events, frames) = scene.detect(x)
        let recorder = FeatureWindowRecorder(windowSeconds: 1.2)
        recorder.append(frames)
        let push = try #require(events.first { $0.isAccepted })
        let sample = try #require(recorder.window(endingAt: push.end + 0.15, label: "push", pilots: [19_000]))
        #expect(sample.features.count == recorder.windowFrames)
        #expect(sample.features[0].count == LabeledSample.perBand.count)
        #expect(recorder.window(endingAt: 0.5, label: "none", pilots: [19_000]) == nil)  // not enough history

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wave-samples-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try SampleExport.write([sample, sample], to: dir, name: "t")
        let csvLines = try String(contentsOf: urls.csv, encoding: .utf8).split(separator: "\n")
        #expect(csvLines.count == 1 + 2 * recorder.windowFrames)
        #expect(csvLines[0].hasPrefix("sample,label,frame,time,b0_toward_db"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: urls.json)) as? [String: Any]
        #expect((json?["samples"] as? [Any])?.count == 2)
    }
}

@Suite("Media activity")
struct MediaActivityTests {
    @Test func listingWorksAndExcludesSelf() {
        // Can't control what else is playing; just check it answers and helper names map to their app.
        #expect(MediaActivity.activeOutputProcesses() != nil)
        #expect(MediaActivity.owningApp(of: "org.example.app.helper.Renderer") == "org.example.app")
    }
}
