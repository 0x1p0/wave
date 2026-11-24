import AppKit
import AVFoundation
import Foundation
import Observation
import WaveCore
import WaveUI

/// Scripted, self-advancing recording session: each step shows what to do, records raw sonar audio, and
/// logs every detection (with reasons) on a clock shared with the webcam video.
@MainActor
@Observable
final class DemoSession {
    struct Step {
        let id: String
        let title: String
        let instruction: String
        let seconds: Double
        let lesson: Lesson.Kind
        var stereo = false
    }

    static let steps: [Step] = [
        Step(id: "still", title: "Sit still",
             instruction: "Hands in your lap, away from the laptop. Don't type or touch the trackpad.",
             seconds: 8, lesson: .sonar),
        Step(id: "push", title: "Push × 5",
             instruction: "Push your open hand toward the screen and straight back out — quick, about half a second. Five times, about 3 seconds apart.",
             seconds: 22, lesson: .push),
        Step(id: "pull", title: "Pull × 5",
             instruction: "Hold your hand still, close to the screen (10–15 cm). Then flick it AWAY toward you and straight back — the away part quick, like a push. Five times, pausing in between.",
             seconds: 25, lesson: .pull),
        Step(id: "hover", title: "Hover controls",
             instruction: "Bring your hand up about 20 cm from the screen and HOLD IT STILL until ✋ appears. Then push = up, pull = down, two or three times. Then move your hand away. Repeat if there's time.",
             seconds: 32, lesson: .hover),
        Step(id: "grab", title: "Fist × 4",
             instruction: "Hold your open hand up, then close it into a fist quickly and firmly (fingers snapping onto the palm). Open it, wait a couple of seconds, repeat.",
             seconds: 28, lesson: .grab),
        Step(id: "swipe", title: "Swipes",
             instruction: "Swipe your hand across the laptop, 15–30 cm in front of the screen, briskly: left → right, pause, right → left. Three of each.",
             seconds: 28, lesson: .swipe, stereo: true),
    ]

    enum Phase: Equatable {
        /// Waiting for the user to start their screen recording and click Start.
        case waitingForStart
        case starting(String)
        case getReady(step: Int, remaining: Int)
        case running(step: Int)
        case finished(String)
        case failed(String)
    }

    struct FeedItem: Identifiable {
        let id = UUID()
        let time: Double
        let text: String
        let good: Bool
    }

    private(set) var phase: Phase = .starting("Preparing…")
    private(set) var stepRemaining: Double = 0
    private(set) var feed: [FeedItem] = []
    private(set) var toast: FeedItem?
    private(set) var engineStatus = ""
    let tutorial = TutorialModel(lessons: [.sonar, .push, .pull, .hover, .grab, .swipe])
    let camera = CameraRecorder()
    private(set) var cameraOn = false
    let directory: URL

    @ObservationIgnored private var engine: SonarEngine?
    @ObservationIgnored private var clockStart = Date()
    @ObservationIgnored private var log = SessionLog()
    @ObservationIgnored private var currentStep: Int?
    @ObservationIgnored private var lastPhase: InteractionDetector.Phase = .idle
    @ObservationIgnored private var relaunchWave: URL?
    @ObservationIgnored private var startContinuation: CheckedContinuation<Void, Never>?

    /// Called by the Start button.
    func begin() {
        startContinuation?.resume()
        startContinuation = nil
    }

    var sessionTime: Double { Date().timeIntervalSince(clockStart) }
    @ObservationIgnored private var finishedCleanly = false

    init() {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        directory = RecordingWriter.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("Sessions/\(stamp.string(from: Date()))", isDirectory: true)
    }

    // MARK: Run

    func run() async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        phase = .starting("Checking microphone and camera…")
        guard await MicCapture.requestPermission() else {
            phase = .failed("Microphone access is off for Terminal: System Settings → Privacy & Security → Microphone.")
            return
        }
        if await AVCaptureDevice.requestAccess(for: .video), camera.configure() {
            camera.start()
            cameraOn = true
        }

        // One engine at a time: quit the Wave menu bar app for the session (reopened at the end).
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.wave.Wave")
        if let app = running.first {
            relaunchWave = app.bundleURL
            app.terminate()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        let engine = SonarEngine { [weak self] out in
            let session = self
            DispatchQueue.main.async { MainActor.assumeIsolated { session?.ingest(out) } }
        }
        engine.setFrameDelivery(all: true)
        self.engine = engine
        var settings = EngineSettings()
        engine.start(settings)

        // Wait until the user has their screen recording running and clicks Start.
        phase = .waitingForStart
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in startContinuation = c }
        for n in stride(from: 3, through: 1, by: -1) {
            phase = .starting("Hands in your lap… \(n)")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        clockStart = Date()
        if cameraOn { camera.snapshot(to: directory.appendingPathComponent("camera"), clock: clockStart) }
        log.cameraFile = cameraOn ? "camera/<seconds>.jpg" : nil
        log.started = Date()

        for (i, step) in Self.steps.enumerated() {
            // Get ready (and switch to two tones for swipes).
            let wantStereo = step.stereo
            if wantStereo != settings.layout.isStereo {
                settings.layout = wantStereo ? .stereo(left: 18_750, right: 19_250) : .single(19_000)
                engine.update(settings)
            }
            tutorial.index = tutorial.lessons.firstIndex { $0.kind == step.lesson } ?? 0
            for n in stride(from: 4, through: 1, by: -1) {
                phase = .getReady(step: i, remaining: n)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // Run.
            tutorial.index = tutorial.lessons.firstIndex { $0.kind == step.lesson } ?? 0
            currentStep = i
            log.steps.append(StepLog(id: step.id, title: step.title, start: sessionTime))
            engine.startRecording(directory: directory, label: step.id)
            phase = .running(step: i)
            let end = Date().addingTimeInterval(step.seconds)
            while Date() < end {
                stepRemaining = end.timeIntervalSinceNow
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            engine.stopRecording()
            log.steps[log.steps.count - 1].end = sessionTime
            log.steps[log.steps.count - 1].progress = tutorial.progress
            currentStep = nil
            writeLog()
        }

        guard !finishedCleanly else { return }
        finishedCleanly = true
        phase = .finished("Saving…")
        engine.stopAndWait()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in camera.stop { c.resume() } }
        writeLog()
        try? "done\n".write(to: directory.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
        if let url = relaunchWave {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        let ok = log.steps.map { "\($0.title): \($0.progress)" }.joined(separator: " · ")
        phase = .finished("All done — thank you! \(ok). Saved to \(directory.path)")
    }

    /// Window closed / quit before the end: keep everything recorded so far (finalised video, log,
    /// raw audio) and reopen the Wave app.
    func finishEarly() async {
        guard !finishedCleanly else { return }
        finishedCleanly = true
        if let engine {
            engine.stopRecording()
            if currentStep != nil, !log.steps.isEmpty {
                log.steps[log.steps.count - 1].end = sessionTime
                log.steps[log.steps.count - 1].progress = tutorial.progress
            }
            engine.stopAndWait()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in camera.stop { c.resume() } }
        writeLog()
        try? "partial\n".write(to: directory.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
        if let url = relaunchWave {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Engine output

    private func ingest(_ out: EngineOutput) {
        engineStatus = out.status.text
        tutorial.ingest(frames: out.frames, events: out.events, controls: out.controls, phase: out.interactionPhase)
        let now = sessionTime
        let streamNow = out.frames.last?.time
        func sessionTimeOf(_ streamTime: Double) -> Double {
            guard let streamNow else { return now }
            return now - max(0, streamNow - streamTime)
        }
        if out.interactionPhase != lastPhase {
            lastPhase = out.interactionPhase
            appendPhase(out.interactionPhase.rawValue, at: now)
        }
        for c in out.controls {
            let text: String
            switch c {
            case .ready(let t): text = "✋ ready (\(t == 0 ? "volume" : "brightness"))"
            case .targetChanged(let t): text = "✋ switched to \(t == 0 ? "volume" : "brightness")"
            case .adjust(_, let d): text = d > 0 ? "▲ up" : "▼ down"
            case .ended: text = "✋ done"
            }
            report(text, good: true, at: now)
            if let i = currentIndex { log.steps[i].controls.append(LoggedControl(time: now, text: text)) }
        }
        for e in out.events {
            let text = e.isAccepted
                ? "✓ \(e.kind.rawValue.uppercased())" + (e.lag.map { String(format: " (lag %+.0f ms)", $0 * 1000) } ?? "")
                : "✗ \(e.kind.rawValue): \(e.outcome.rawValue)"
            report(text, good: e.isAccepted, at: now)
            if let i = currentIndex {
                log.steps[i].events.append(LoggedEvent(e, start: sessionTimeOf(e.start), end: sessionTimeOf(e.end)))
            }
        }
    }

    private var currentIndex: Int? { currentStep == nil ? nil : log.steps.indices.last }

    private func appendPhase(_ name: String, at t: Double) {
        if let i = currentIndex { log.steps[i].phases.append(LoggedControl(time: t, text: name)) }
    }

    private func report(_ text: String, good: Bool, at t: Double) {
        let item = FeedItem(time: t, text: text, good: good)
        feed.insert(item, at: 0)
        if feed.count > 8 { feed.removeLast() }
        toast = item
    }

    private func writeLog() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(log).write(to: directory.appendingPathComponent("session.json"))
    }
}

// MARK: - Log format (session.json)

struct SessionLog: Codable {
    var started: Date?
    var cameraFile: String?
    var steps: [StepLog] = []
}

struct StepLog: Codable {
    var id: String
    var title: String
    var start: Double
    var end: Double = 0
    var progress = 0
    var events: [LoggedEvent] = []
    var controls: [LoggedControl] = []
    var phases: [LoggedControl] = []
}

struct LoggedEvent: Codable {
    var start: Double
    var end: Double
    var kind: String
    var outcome: String
    var confidence: Double
    var towardPeakDB: Float
    var awayPeakDB: Float
    var duration: Double
    var lagMs: Double?
    var microPeakDB: Float?

    init(_ e: GestureEvent, start: Double, end: Double) {
        self.start = start
        self.end = end
        kind = e.kind.rawValue
        outcome = e.outcome.rawValue
        confidence = e.confidence
        towardPeakDB = e.towardPeakDB
        awayPeakDB = e.awayPeakDB
        duration = e.duration
        lagMs = e.lag.map { $0 * 1000 }
        microPeakDB = e.microPeakDB
    }
}

struct LoggedControl: Codable {
    var time: Double
    var text: String
}
