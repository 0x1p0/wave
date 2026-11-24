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
        /// What should be detected in this step (empty: nothing should happen). Used by the report.
        var expect: [GestureEvent.Kind] = []
        /// Shows a text box to type into (the "type normally" step).
        var typing = false
        /// Needs the two tones (air letters).
        var stereo = false
        /// Plays a chime when the step ends (you're away from the screen and can't see it).
        var chime = false
        /// What else should happen (presence / drawing), for the report.
        var expectNote: String?
    }

    /// `wave-demo --extras` (make session-extras): walk away / come back and air letters, instead of the gestures.
    static var steps: [Step] { CommandLine.arguments.contains("--extras") ? extraSteps : gestureSteps }

    /// Every gesture, one labelled step each, so the report knows what you meant at every moment; then
    /// everyday use where nothing should fire.
    static let gestureSteps: [Step] = [
        Step(id: "still", title: "Sit still",
             instruction: "Hands in your lap, away from the laptop. Don't type or touch the trackpad.",
             seconds: 8, lesson: .sonar),
        Step(id: "push", title: "Push × 5",
             instruction: "Push your open hand toward the screen and straight back out, quick (about half a second). Five times, about 3 seconds apart.",
             seconds: 20, lesson: .push, expect: [.push]),
        Step(id: "swipe-left", title: "Swipe LEFT only × 6",
             instruction: "Move your hand across the laptop from RIGHT to LEFT, 15–30 cm in front of the screen, briskly. After each one, drop your hand down and bring it back to the right low, out of the way. Six times.",
             seconds: 24, lesson: .swipe, expect: [.swipeLeft]),
        Step(id: "swipe-right", title: "Swipe RIGHT only × 6",
             instruction: "Now the other way: from LEFT to RIGHT across the laptop, briskly. After each one, drop your hand and bring it back to the left low. Six times.",
             seconds: 24, lesson: .swipe, expect: [.swipeRight]),
        Step(id: "swipe-both", title: "Swipes, both ways",
             instruction: "Swipe left, then right, then left… the way you'd naturally switch back and forth, with a short pause between.",
             seconds: 20, lesson: .swipe, expect: [.swipeLeft, .swipeRight]),
        Step(id: "fist", title: "Fist × 5",
             instruction: "Hold your open hand up about 20 cm in front of the screen, then close it into a fist quickly and firmly. Open it, lower your hand, wait two seconds, repeat.",
             seconds: 24, lesson: .grab, expect: [.grab]),
        Step(id: "hover", title: "Volume by hovering",
             instruction: "Push your hand TOWARD the screen and keep it there, about 20 cm away, REALLY still, until ✋ appears. Then QUICK pushes = up, QUICK pulls = down (brisk like play/pause; gentle presses don't register). Move your hand away. Repeat.",
             seconds: 28, lesson: .hover),
        // Everyday use: nothing should fire here.
        Step(id: "typing", title: "Type normally",
             instruction: "No gestures now. Type in the box below: anything, at your usual speed, with your natural pauses. Use the trackpad too: click, scroll.",
             seconds: 20, lesson: .sonar, typing: true),
        Step(id: "everyday", title: "Use your Mac normally",
             instruction: "No gestures, no typing. Reach for your drink or phone, lean in and back, scratch your face, rest your hands on the laptop: whatever you usually do.",
             seconds: 20, lesson: .sonar),
        Step(id: "taps", title: "Taps",
             instruction: "No gestures. Tap the desk next to the laptop a few times, then tap the palm rest (not the keys), then rest your palms on it.",
             seconds: 12, lesson: .sonar),
    ]

    /// Walk away / come back, then air letters. Nothing should *fire* while you shift around in your chair.
    static let extraSteps: [Step] = [
        Step(id: "still", title: "Sit still",
             instruction: "Hands in your lap, away from the laptop. Don't type or touch the trackpad.",
             seconds: 8, lesson: .sonar),
        Step(id: "lean", title: "Shift around in your chair",
             instruction: "Stay seated. Lean back and stretch, lean in to read the screen, turn to look at something, settle back. No gestures, no typing.",
             seconds: 24, lesson: .sonar, expectNote: "no 'left'"),
        Step(id: "leave", title: "Get up and walk away",
             instruction: "Stand up and walk out of the room (or at least 3 metres away) and stay there. A chime tells you to come back (in 30 seconds).",
             seconds: 30, lesson: .sonar, chime: true, expectNote: "left"),
        Step(id: "return", title: "Come back",
             instruction: "Walk back and sit down in front of the laptop. Don't touch the keyboard or trackpad yet.",
             seconds: 12, lesson: .sonar, expectNote: "returned"),
        Step(id: "draw-z", title: "Draw a Z × 3",
             instruction: "Draw a big Z in the air, about 20 cm in front of the screen, in one go (about a second). Drop your hand, wait 3 seconds, again. Three times.",
             seconds: 22, lesson: .swipe, stereo: true, expectNote: "3 drawings"),
        Step(id: "draw-o", title: "Draw a circle × 3",
             instruction: "Now a big circle, the same way: in one go, about a second, about 20 cm in front of the screen. Three times, 3 seconds apart.",
             seconds: 22, lesson: .swipe, stereo: true, expectNote: "3 drawings"),
        Step(id: "draw-z-again", title: "Z again × 3",
             instruction: "The Z again, three times, the way you drew it before (this checks Wave can tell Z from a circle).",
             seconds: 22, lesson: .swipe, stereo: true, expectNote: "3 drawings"),
        Step(id: "swipe-both", title: "Swipes, both ways",
             instruction: "Swipe left, then right, then left… with a short pause between. These must stay swipes, not drawings.",
             seconds: 20, lesson: .swipe, expect: [.swipeLeft, .swipeRight]),
    ]

    /// Wave's saved preferences (the menu bar app's), as JSON.
    static var appPrefs: [String: Any] {
        guard let data = UserDefaults(suiteName: "local.wave.Wave")?.data(forKey: "WavePreferences.v1"),
              let prefs = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return prefs
    }

    /// The pilot layout the Wave app itself uses (two tones when swipes are on).
    static func appLayout() -> PilotLayout {
        let prefs = appPrefs
        let push = prefs["pushPilotHz"] as? Double ?? 19_000
        guard prefs["swipesEnabled"] as? Bool == true else { return .single(push) }
        let left = prefs["leftPilotHz"] as? Double ?? 18_750
        var right = prefs["rightPilotHz"] as? Double ?? 19_250
        if right == 19_500 && left == 18_750 { right = 19_250 }  // same migration as the app
        return .stereo(left: left, right: right)
    }

    /// Exactly the engine settings the Wave app runs with (mirrors WavePreferences.engineSettings), so the
    /// session tests what you actually use.
    static func appSettings() -> EngineSettings {
        let prefs = appPrefs
        var s = EngineSettings()
        s.layout = appLayout()
        if let level = prefs["levelDBFS"] as? Double { s.level.referenceAmplitudeDBFS = level }
        if let cal = prefs["calibration"], !(cal is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: cal),
           let profile = try? JSONDecoder().decode(CalibrationProfile.self, from: data), profile.layout == s.layout {
            s.detector = profile.detector
            s.fusion = profile.fusion
            if let i = profile.interaction { s.interaction = i }
        }
        s.detector.sensitivity = prefs["sensitivity"] as? Double ?? 0.5
        let targets = (prefs["dialTargets"] as? [Any])?.count ?? 2
        s.interaction.dialEnabled = (prefs["dialEnabled"] as? Bool ?? true) && targets > 0
        s.interaction.dialTargets = max(1, targets)
        s.interaction.dialStep = (prefs["dialStep"] as? Double ?? 10) / 100
        s.interaction.grabEnabled = prefs["grabEnabled"] as? Bool ?? true
        s.interaction.pullEnabled = actionName(for: "pull") != "Nothing"
        return s
    }

    /// What the Wave app would do for a gesture ("Next desktop", "Play/Pause", "Nothing").
    static func actionName(for gesture: String) -> String {
        let defaults = ["push": "Play/Pause", "swipeLeft": "Previous track", "swipeRight": "Next track",
                        "grab": "Minimize window", "pull": "Nothing"]
        guard let mapping = appPrefs["mapping"] as? [String: Any], let action = mapping[gesture] as? [String: Any],
              let (kind, value) = action.first else { return defaults[gesture] ?? "?" }
        let inner = (value as? [String: Any])?["_0"]
        switch kind {
        case "none": return "Nothing"
        case "media":
            let media = [16: "Play/Pause", 17: "Next track", 18: "Previous track", 19: "Fast forward", 20: "Rewind",
                         0: "Volume up", 1: "Volume down", 7: "Mute"]
            return media[(inner as? Int) ?? -1] ?? "Media key"
        case "system": return (inner as? String).map(Self.spaced) ?? "System action"
        case "key": return "Keyboard shortcut"
        case "shortcut": return "Shortcut \((inner as? String) ?? "")"
        default: return kind
        }
    }

    /// "minimizeWindow" → "Minimize window".
    private static func spaced(_ id: String) -> String {
        var out = ""
        for c in id {
            if c.isUppercase { out += " " + c.lowercased() } else { out.append(c) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    static func mappingKey(_ kind: GestureEvent.Kind) -> String {
        switch kind {
        case .push: return "push"
        case .pull: return "pull"
        case .grab: return "grab"
        case .swipeLeft: return "swipeLeft"
        case .swipeRight: return "swipeRight"
        }
    }

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
        var settings = Self.appSettings()
        let appLayout = settings.layout
        log.layout = appLayout.description
        log.settings = String(describing: settings)
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
            let needsSwipes = step.stereo || step.expect.contains(.swipeLeft) || step.expect.contains(.swipeRight)
            let wanted: PilotLayout = needsSwipes && !appLayout.isStereo ? .stereo(left: 18_750, right: 19_250) : appLayout
            if wanted != settings.layout {
                settings.layout = wanted
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
            log.steps.append(StepLog(id: step.id, title: step.title, start: sessionTime,
                                     expect: step.expect.map(\.rawValue), expectNote: step.expectNote))
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
            if step.chime { NSSound(named: "Glass")?.play() }
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
        for p in out.presence {
            let text: String
            switch p {
            case .maybeLeaving: text = "🚶 maybe leaving"
            case .stillHere: text = "🚶 still here"
            case .left: text = "🚶 LEFT (would pause / lock)"
            case .returned: text = "🚶 RETURNED (would resume)"
            }
            report(text, good: true, at: now)
            if let i = currentIndex { log.steps[i].controls.append(LoggedControl(time: now, text: text)) }
        }
        for a in out.air {
            let text: String
            switch a {
            case .drawingStarted: text = "✍️ drawing…"
            case .drawn(let d): text = String(format: "✍️ DRAWN (%.1f s)", d.duration)
            case .drawingAbandoned: text = "✍️ not a drawing"
            }
            report(text, good: true, at: now)
            if let i = currentIndex {
                log.steps[i].controls.append(LoggedControl(time: now, text: text))
                if case .drawn(let d) = a { log.steps[i].drawings.append(d) }
            }
        }
        for e in out.events {
            let action = Self.actionName(for: Self.mappingKey(e.kind))
            let text = e.isAccepted
                ? "✓ \(e.kind.rawValue.uppercased()) → \(action)" + (e.lag.map { String(format: " (lag %+.0f ms)", $0 * 1000) } ?? "")
                : "✗ \(e.kind.rawValue): \(e.outcome.rawValue)"
            report(text, good: e.isAccepted, at: now)
            if let i = currentIndex {
                var logged = LoggedEvent(e, start: sessionTimeOf(e.start), end: sessionTimeOf(e.end))
                logged.action = e.isAccepted ? action : nil
                log.steps[i].events.append(logged)
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
    /// Pilot layout used (matches the Wave app's).
    var layout: String?
    /// The engine settings used (the Wave app's).
    var settings: String?
    var steps: [StepLog] = []
}

struct StepLog: Codable {
    var id: String
    var title: String
    var start: Double
    var expect: [String] = []
    var expectNote: String?
    var end: Double = 0
    var progress = 0
    var events: [LoggedEvent] = []
    var controls: [LoggedControl] = []
    var phases: [LoggedControl] = []
    /// Air-letter drawings (their shapes), to check Z vs circle offline.
    var drawings: [AirDrawing] = []
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
    var towardVelocity: Float
    var awayVelocity: Float
    var referenceDB: Float
    /// What the Wave app would have done (accepted events only).
    var action: String?

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
        towardVelocity = e.towardPeakVelocity
        awayVelocity = e.awayPeakVelocity
        referenceDB = e.maxReferenceDB
    }
}

struct LoggedControl: Codable {
    var time: Double
    var text: String
}
