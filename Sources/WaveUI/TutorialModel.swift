import Foundation
import SwiftUI
import Observation
import WaveCore

/// One lesson of the gesture tutorial.
public struct Lesson: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case sonar, push, pull, hover, grab, swipe
    }

    public let kind: Kind
    public var id: String { kind.rawValue }

    public var title: String {
        switch kind {
        case .sonar: return "See your hand"
        case .push: return "Push"
        case .pull: return "Pull"
        case .hover: return "Hover controls"
        case .grab: return "Fist"
        case .swipe: return "Swipe"
        }
    }

    /// Matches the gesture colours in the app's menu and Settings.
    public var tint: Color {
        switch kind {
        case .sonar: return .green
        case .push: return .blue
        case .pull: return .indigo
        case .hover: return .pink
        case .grab: return .orange
        case .swipe: return .teal
        }
    }

    public var symbol: String {
        switch kind {
        case .sonar: return "dot.radiowaves.left.and.right"
        case .push: return "hand.raised.fill"
        case .pull: return "arrow.uturn.backward"
        case .hover: return "dial.medium.fill"
        case .grab: return "hand.raised.fingers.spread.fill"
        case .swipe: return "arrow.left.and.right"
        }
    }

    public var experimental: Bool { kind == .grab }

    public var instructions: String {
        switch kind {
        case .sonar:
            return "Wave plays a tone you can't hear and listens to its echo. Move your hand around in front of the screen and watch: moving toward the screen glows green, moving away glows orange. Try it a few times."
        case .push:
            return "Move your open hand toward the screen and straight back out, in about half a second, 10–30 cm in front of it. Outside practice this plays or pauses."
        case .pull:
            return "Start with your hand still, close to the screen (10–15 cm). Flick it AWAY toward you and straight back, as briskly as a push. Wave reads whichever way you moved first, so the away part has to be the quick one — a slow drift away followed by a quick return looks like a push."
        case .hover:
            return "Don't touch the keyboard or trackpad for a couple of seconds. Bring your hand up briskly, about 20 cm from the screen, and hold it really still until ✋ appears (about a second). Then push to turn up and pull to turn down (10 % each). Hold still for 3 s to switch between volume and brightness. Move your hand away to finish."
        case .grab:
            return "Hold your open hand up in front of the screen, then close it into a fist quickly and firmly — fingers snapping onto your palm. Wave hears that snap: watch the Snap meter jump past the line. Opening your hand again doesn't count, so take a second between fists."
        case .swipe:
            return "Swipe your hand across the laptop, 15–30 cm in front of the screen, briskly. The two lanes (left and right tone) should light up one after the other."
        }
    }

    public var goal: Int {
        switch kind {
        case .hover: return 3  // up, down, done
        case .grab, .swipe: return 2
        default: return 3
        }
    }
}

/// Live state for the tutorial, fed from the engine. Main actor only.
@MainActor
@Observable
public final class TutorialModel {
    public let lessons: [Lesson]
    public var index = 0 { didSet { if index != oldValue { startLesson() } } }
    public var lesson: Lesson { lessons[index] }

    // Live "how Wave sees your hand"
    /// Hand position −1 (at the screen) … +1 (far), from integrated Doppler / phase motion.
    public private(set) var handPosition: Double = 0.2
    public private(set) var toward: Double = 0
    public private(set) var away: Double = 0
    /// Broadband "snap" level (a fist closing), 0…1.
    public private(set) var snap: Double = 0
    public private(set) var lanes: [Double] = []
    public private(set) var phase: InteractionDetector.Phase = .idle
    public private(set) var grabLine: Double

    // Progress and coaching
    public private(set) var progress = 0
    public private(set) var completed: Set<String> = []
    public private(set) var feedback = ""
    public private(set) var feedbackGood = false
    public private(set) var feedbackSerial = 0
    /// Practice level for the hover lesson (doesn't touch the real volume).
    public private(set) var practiceLevel = 0.5
    public private(set) var practiceTarget = 0
    public let dialTargetNames: [String]
    private var hoverSteps: Set<String> = []

    @ObservationIgnored private var lastFrameTime: Double?
    @ObservationIgnored private let onThresholdDB: Float

    public init(lessons: [Lesson.Kind], grabSnapDB: Float = InteractionConfig().grabSnapDB,
                onThresholdDB: Float = DetectorConfig().effectiveOnDB, dialTargetNames: [String] = ["Volume", "Brightness"]) {
        self.lessons = lessons.map { Lesson(kind: $0) }
        self.onThresholdDB = onThresholdDB
        self.dialTargetNames = dialTargetNames
        grabLine = Double(grabSnapDB) / 30
        startLesson()
    }

    public var isComplete: Bool { completed.contains(lesson.id) }

    public var hoverChecklist: [(String, Bool)] {
        [("Hold until ✋", hoverSteps.contains("ready")), ("Push to turn up", hoverSteps.contains("up")),
         ("Pull to turn down", hoverSteps.contains("down")), ("Move away to finish", hoverSteps.contains("ended"))]
    }

    public func next() { if index + 1 < lessons.count { index += 1 } }
    public func back() { if index > 0 { index -= 1 } }

    private func startLesson() {
        progress = 0
        hoverSteps = []
        practiceLevel = 0.5
        practiceTarget = 0
        say("", good: false)
    }

    // MARK: Engine output

    public func ingest(frames: [PipelineFrame], events: [GestureEvent], controls: [ControlEvent], phase: InteractionDetector.Phase) {
        if self.phase != phase { self.phase = phase }
        for f in frames { track(f) }
        for c in controls { handle(c) }
        for e in events { handle(e) }
    }

    private func track(_ frame: PipelineFrame) {
        // The first band is the lowest-frequency (strongest) tone.
        guard let f = frame.bands.first else { return }
        let dt = lastFrameTime.map { min(0.1, max(0, frame.time - $0)) } ?? 0
        lastFrameTime = frame.time
        // Position: Doppler speed while there's clear motion, else the phase-tracked speed; drifts back
        // to the middle so the picture stays readable.
        let on = onThresholdDB
        var v = Double(f.basebandVelocity)
        if (f.towardDB >= on || f.awayDB >= on) && abs(f.velocity) >= 0.2 { v = Double(f.velocity) }
        handPosition -= v * dt / 0.15  // 15 cm ≈ full scale
        handPosition += (0.2 - handPosition) * min(1, dt / 1.5)
        handPosition = min(1, max(-1, handPosition))
        toward += (min(1, max(0, Double(f.towardDB) / 25)) - toward) * 0.5
        away += (min(1, max(0, Double(f.awayDB) / 25)) - away) * 0.5
        snap = max(min(1, max(0, Double(f.referenceDB) / 30)), snap * 0.85)  // fast attack, slow fade: a snap is ~80 ms
        let newLanes = frame.bands.map { min(1, max(0, Double(max($0.towardDB, $0.awayDB)) / 25)) }
        if lanes.count != newLanes.count { lanes = newLanes } else {
            for i in lanes.indices { lanes[i] += (newLanes[i] - lanes[i]) * 0.5 }
        }
        if lesson.kind == .sonar, f.towardDB >= on || f.awayDB >= on, frame.time - lastSonarCount > 0.6 {
            lastSonarCount = frame.time
            count(good: "✓ Wave sees your hand move \(f.towardDB > f.awayDB ? "toward the screen" : "away")")
        }
    }

    @ObservationIgnored private var lastSonarCount = -10.0

    private func handle(_ c: ControlEvent) {
        switch c {
        case .ready(let t):
            practiceTarget = t
            if lesson.kind == .hover { hoverSteps.insert("ready"); say("✋ Ready — now push to turn up, pull to turn down", good: true) }
        case .targetChanged(let t):
            practiceTarget = t
            if lesson.kind == .hover { say("Switched to \(name(t)) — holding still switches", good: true) }
        case .adjust(_, let d):
            practiceLevel = min(1, max(0, practiceLevel + d))
            if lesson.kind == .hover {
                hoverSteps.insert(d > 0 ? "up" : "down")
                say(d > 0 ? "▲ \(name(practiceTarget)) up" : "▼ \(name(practiceTarget)) down", good: true)
            }
        case .ended:
            if lesson.kind == .hover && hoverSteps.contains("ready") {
                hoverSteps.insert("ended")
                say("Done — the overlay closes when you move away", good: true)
            }
        }
        if lesson.kind == .hover {
            progress = ["up", "down", "ended"].filter(hoverSteps.contains).count
            if progress >= lesson.goal { completed.insert(lesson.id) }
        }
    }

    private func handle(_ e: GestureEvent) {
        let want: GestureEvent.Kind? = {
            switch lesson.kind {
            case .push: return .push
            case .pull: return .pull
            case .grab: return .grab
            default: return nil
            }
        }()
        if e.isAccepted {
            if lesson.kind == .swipe {
                if e.kind == .swipeLeft || e.kind == .swipeRight {
                    count(good: "✓ \(e.kind == .swipeLeft ? "Swipe left" : "Swipe right")!")
                } else if e.kind == .push {
                    say("That looked like a push (both tones at once). Swipe sideways, across the laptop.", good: false)
                }
            } else if let want {
                if e.kind == want {
                    count(good: "✓ \(e.kind.rawValue.capitalized)! (confidence \(Int(e.confidence * 100)) %)")
                } else {
                    say(mismatch(got: e.kind, want: want), good: false)
                }
            }
        } else if let want, e.kind == want {
            // A near miss of the gesture being practised: say why it didn't count.
            say(coaching(e), good: false)
        }
    }

    private func count(good message: String) {
        guard !isComplete else { say(message, good: true); return }
        progress = min(lesson.goal, progress + 1)
        if progress >= lesson.goal {
            completed.insert(lesson.id)
            say(message + " — lesson complete 🎉", good: true)
        } else {
            say(message, good: true)
        }
    }

    private func say(_ message: String, good: Bool) {
        feedback = message
        feedbackGood = good
        feedbackSerial += 1
    }

    private func name(_ target: Int) -> String {
        dialTargetNames.indices.contains(target) ? dialTargetNames[target] : "Level"
    }

    private func mismatch(got: GestureEvent.Kind, want: GestureEvent.Kind) -> String {
        switch (got, want) {
        case (.pull, .push): return "That was a pull (away first). For a push, go toward the screen first, then back."
        case (.push, .pull): return "That was a push (toward first). For a pull, start close and move away first."
        default: return "Wave saw a \(got.rawValue), not a \(want.rawValue)."
        }
    }

    private func coaching(_ e: GestureEvent) -> String {
        let pull = e.kind == .pull
        switch e.outcome {
        case .tooSlow: return "Almost — that was a bit slow. Make it quicker, about half a second."
        case .tooFast: return "Too quick — do it a little slower."
        case .noReturn: return pull ? "You moved away but didn't come back. Come straight back in." : "You moved in but didn't come back out. Come straight back out."
        case .weak: return pull ? "Too small — start closer to the screen and move further away." : "Too small — move a little further, or a bit closer to the screen."
        case .recentInput: return "You just typed or touched the trackpad — keep your hands off for a second."
        case .noiseBurst: return "Lots of rustling noise (sleeves, rings?) — try again a bit more smoothly."
        case .oneSided: return "Only one speaker saw that — try nearer the middle of the laptop."
        case .sideways: return "That moved sideways — a push goes straight toward the screen; a swipe needs to cross the laptop briskly."
        case .accepted: return ""
        }
    }

    // MARK: Text for the live view

    public var phaseText: String {
        switch phase {
        case .idle: return lesson.kind == .hover || lesson.kind == .grab ? "Waiting — bring your hand up" : "Listening"
        case .approaching: return "Hand coming toward the screen"
        case .holding: return "Holding still… ✋ in a moment"
        case .ready: return "✋ Ready"
        case .cooldown: return "Done"
        }
    }
}
