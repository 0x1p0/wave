import Foundation
import Testing
@testable import WaveCore

/// Test wrapper around `SyntheticScene` that runs the full pipeline.
struct Scene {
    static let fs = SyntheticScene.sampleRate
    static let handEcho = SyntheticScene.handEcho
    var base = SyntheticScene(duration: 4)

    var count: Int { base.count }

    func render(echoes: [(amplitude: Float, velocity: (Double) -> Double)] = [], extra: [Float] = []) -> [Float] {
        base.render(echoes: echoes.map { SyntheticScene.Echo(amplitude: $0.amplitude, velocity: $0.velocity) }, extra: extra)
    }

    func burst(start: Double, length: Double, rms: Float) -> [Float] { base.burst(start: start, length: length, rms: rms) }

    /// Runs the full pipeline in 10 ms chunks, feeding input times in order.
    func detect(_ x: [Float], inputs: [Double] = [], config: DetectorConfig = DetectorConfig()) -> (events: [GestureEvent], frames: [PipelineFrame]) {
        let pipeline = GesturePipeline(sampleRate: Self.fs, channels: 1, pilots: [19_000], detector: config)
        var events: [GestureEvent] = []
        var frames: [PipelineFrame] = []
        var i = 0
        var next = 0
        while i < x.count {
            let end = min(x.count, i + 480)
            let t = Double(end) / Self.fs
            while next < inputs.count && inputs[next] <= t { pipeline.noteInput(at: inputs[next]); next += 1 }
            let out = pipeline.process([Array(x[i..<end])])
            events += out.events
            frames += out.frames
            i = end
        }
        return (events, frames)
    }
}

@Suite("Push detection — synthetic Doppler")
struct PushDetectionTests {
    let scene = Scene()

    @Test func cleanPushIsDetectedOnce() throws {
        let x = scene.render(echoes: [(Scene.handEcho, SyntheticSignal.pushVelocity(start: 1.5))])
        let accepted = scene.detect(x).events.filter(\.isAccepted)
        try #require(accepted.count == 1)
        let e = accepted[0]
        #expect(e.start > 1.45 && e.start < 1.75)
        #expect(e.duration > 0.3 && e.duration < 0.75)
        #expect(e.towardPeakDB > 12 && e.awayPeakDB > 12)
        #expect(e.towardPeakVelocity > 0.4 && e.awayPeakVelocity < -0.4)
        #expect(e.confidence > 0.5)
    }

    @Test func twoPushesAreTwoEvents() {
        let v1 = SyntheticSignal.pushVelocity(start: 1.2)
        let v2 = SyntheticSignal.pushVelocity(start: 2.8, peak: 1.0)
        let x = scene.render(echoes: [(Scene.handEcho, { v1($0) + v2($0) })])
        #expect(scene.detect(x).events.filter(\.isAccepted).count == 2)
    }

    @Test(arguments: [0.5, 0.8, 1.2])
    func pushSpeedsAreAccepted(peak: Double) {
        let x = scene.render(echoes: [(Scene.handEcho, SyntheticSignal.pushVelocity(start: 1.5, peak: peak))])
        #expect(scene.detect(x).events.filter(\.isAccepted).count == 1)
    }

    @Test func featuresAreQuietWithoutMotion() {
        let frames = scene.detect(scene.render()).frames.filter { $0.time > 1 }
        let toward = frames.map { $0.bands[0].towardDB }
        let away = frames.map { $0.bands[0].awayDB }
        #expect(Stats.percentile(toward, 0.99) < 3)
        #expect(Stats.percentile(away, 0.99) < 3)
        #expect(frames.allSatisfy { $0.bands[0].velocity == 0 || abs($0.bands[0].velocity) < 0.5 })
    }

    @Test func velocityEstimateTracksConstantMotion() {
        // Steady 0.6 m/s toward from 1 s on: the centroid should read ~0.6 m/s.
        let x = scene.render(echoes: [(Scene.handEcho, { $0 > 1 ? 0.6 : 0 })])
        let v = scene.detect(x).frames.filter { $0.time > 1.3 && $0.time < 2.5 }.map { $0.bands[0].velocity }
        #expect(abs(Stats.median(v) - 0.6) < 0.1)
    }
}

@Suite("Push detection — false triggers")
struct FalseTriggerTests {
    let scene = Scene()

    @Test func silenceAndNoiseOnly() {
        #expect(scene.detect(scene.render()).events.isEmpty)
    }

    @Test func slowDriftIsIgnored() {
        // 0.1 m/s ≈ 11 Hz Doppler: inside the pilot's own excluded bins.
        let x = scene.render(echoes: [(Scene.handEcho * 3, { _ in 0.1 })])
        #expect(scene.detect(x).events.filter(\.isAccepted).isEmpty)
    }

    @Test func oneWayMotionIsNotAPush() {
        // Someone/something approaching steadily for 1.5 s (strong echo): never returns.
        let x = scene.render(echoes: [(Scene.handEcho, { $0 > 1 && $0 < 2.5 ? 1.0 : 0 })])
        #expect(scene.detect(x).events.filter(\.isAccepted).isEmpty)
    }

    @Test func distantWalkerIsIgnored() {
        // Person walking behind: weak echo (~−40 dB below the hand) moving both ways.
        let x = scene.render(echoes: [(Scene.handEcho / 100, { 1.2 * sin(2 * Double.pi * 0.7 * $0) })])
        #expect(scene.detect(x).events.isEmpty)
    }

    @Test func slowPushIsRejected() {
        let v = SyntheticSignal.pushVelocity(start: 1.0, toward: 0.7, pause: 0.25, away: 0.7, peak: 0.6)
        let x = scene.render(echoes: [(Scene.handEcho, v)])
        #expect(scene.detect(x).events.filter(\.isAccepted).isEmpty)
    }

    @Test func pullIsNotAPush() {
        // Away first, then back toward the screen.
        let push = SyntheticSignal.pushVelocity(start: 1.5)
        let x = scene.render(echoes: [(Scene.handEcho, { -push($0) })])
        #expect(scene.detect(x).events.filter(\.isAccepted).isEmpty)
    }

    @Test func broadbandBurstIsRejected() {
        // 300 ms of rustling, 20 dB above the noise floor across the whole band.
        let x = scene.render(extra: scene.burst(start: 1.5, length: 0.3, rms: 2.6e-4))
        #expect(scene.detect(x).events.filter(\.isAccepted).isEmpty)
    }

    @Test func pushDuringBroadbandBurstIsRejectedAsNoise() {
        let x = scene.render(
            echoes: [(Scene.handEcho, SyntheticSignal.pushVelocity(start: 1.5))],
            extra: scene.burst(start: 1.55, length: 0.15, rms: 1.5e-4))
        let events = scene.detect(x).events
        #expect(events.filter(\.isAccepted).isEmpty)
    }

    @Test func noiseStepIsIgnored() {
        // A fan spinning up: noise floor +10 dB from 2 s on.
        var step = SyntheticSignal.noise(rms: 8e-5, count: scene.count, seed: 3)
        for i in 0..<Int(2 * Scene.fs) { step[i] = 0 }
        #expect(scene.detect(scene.render(extra: step)).events.filter(\.isAccepted).isEmpty)
    }

    @Test func recentInputSuppressesPush() throws {
        let x = scene.render(echoes: [(Scene.handEcho, SyntheticSignal.pushVelocity(start: 1.5))])
        let events = scene.detect(x, inputs: [1.2]).events
        #expect(events.filter(\.isAccepted).isEmpty)
        #expect(events.contains { $0.outcome == .recentInput })
        // Input long enough before (> 0.8 s) does not.
        #expect(scene.detect(x, inputs: [0.6]).events.filter(\.isAccepted).count == 1)
    }

    @Test func sensitivityMovesTheThreshold() {
        // A weak push (echo −8 dB) passes when sensitive, fails when strict.
        let x = scene.render(echoes: [(Scene.handEcho * 0.4, SyntheticSignal.pushVelocity(start: 1.5))])
        var strict = DetectorConfig(); strict.sensitivity = 0
        var sensitive = DetectorConfig(); sensitive.sensitivity = 1
        #expect(scene.detect(x, config: strict).events.filter(\.isAccepted).isEmpty)
        #expect(scene.detect(x, config: sensitive).events.filter(\.isAccepted).count == 1)
    }
}

@Suite("Demo scene")
struct DemoSceneTests {
    @Test func demoProducesTheScriptedOutcomes() {
        let (x, inputs) = SyntheticScene.demo()
        let events = Scene().detect(x, inputs: inputs).events
        let accepted = events.filter(\.isAccepted).map(\.start)
        // 1.5, 3.5 and 12.3 s are clean pushes; the weak one, the burst, the one-way motion and the
        // push right after typing must not be accepted.
        #expect(accepted.count == 3)
        #expect(accepted.contains { abs($0 - 1.55) < 0.25 })
        #expect(accepted.contains { abs($0 - 3.55) < 0.25 })
        #expect(accepted.contains { abs($0 - 12.35) < 0.25 })
        #expect(events.contains { $0.outcome == .recentInput && abs($0.start - 10.55) < 0.25 })
    }
}

@Suite("Record / replay")
struct RecordReplayTests {
    @Test func replayReproducesDetections() throws {
        let scene = Scene()
        let x = scene.render(echoes: [(Scene.handEcho, SyntheticSignal.pushVelocity(start: 1.5))])
        let direct = scene.detect(x, inputs: [0.3]).events

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wave-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var meta = RecordingMetadata(sampleRate: Scene.fs, channels: 1, pilots: [19_000], micDevice: "synthetic", machine: "test")
        meta.label = "push"
        let writer = try RecordingWriter(directory: dir, metadata: meta, streamStart: 10)
        var i = 0
        while i < x.count {
            let end = min(x.count, i + 4800)
            try writer.append([Array(x[i..<end])])
            i = end
        }
        writer.noteInput(at: 10.3)
        let url = try writer.finish()
        #expect(url.pathExtension == "caf")
        #expect(url.lastPathComponent.hasSuffix("-push.caf"))

        let loaded = try LoadedRecording.load(url)
        #expect(loaded.frameCount == x.count)
        #expect(loaded.channels.first.map { $0 == x } == true)
        #expect(loaded.metadata?.inputTimes.count == 1)
        #expect(abs((loaded.metadata?.inputTimes.first ?? 0) - 0.3) < 1e-9)
        #expect(abs((loaded.metadata?.duration ?? 0) - scene.base.duration) < 1e-6)

        let replayed = Replay.run(loaded).events
        #expect(replayed.count == direct.count)
        for (a, b) in zip(replayed, direct) {
            #expect(a.outcome == b.outcome)
            #expect(abs(a.start - b.start) < 1e-9 && abs(a.end - b.end) < 1e-9)
        }
    }
}

@Suite("Volume compensation")
struct PilotLevelPolicyTests {
    let policy = PilotLevelPolicy()

    @Test func referenceVolumeUsesReferenceLevel() {
        #expect(policy.decide(speakerGainDB: -18.6, muted: false) == .play(amplitudeDBFS: -8))
    }

    @Test func louderSpeakersGetAQuieterPilot() {
        guard case .play(let a) = policy.decide(speakerGainDB: -8.6, muted: false) else { Issue.record("not playing"); return }
        #expect(abs(a - -18) < 1e-9)
    }

    @Test func quieterSpeakersAreCompensatedWithinLimits() {
        guard case .play(let a) = policy.decide(speakerGainDB: -24.6, muted: false) else { Issue.record("not playing"); return }
        #expect(abs(a - -2) < 1e-9)
        #expect(policy.decide(speakerGainDB: -30, muted: false).pauseReason == "Volume too low for Wave")
    }

    @Test func mutedPauses() {
        #expect(policy.decide(speakerGainDB: -10, muted: true) == .muted)
        #expect(policy.decide(speakerGainDB: -10, muted: true).pauseReason == "Built-in speakers are muted")
    }
}

@Suite("Input idle")
struct InputIdleTests {
    @Test func hidIdleTimeIsReadable() throws {
        let idle = try #require(InputIdleMonitor().idleSeconds())
        #expect(idle >= 0)
    }
}
