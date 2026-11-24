import AppKit
import Foundation
import WaveCore
import WaveRT

/// `wave-probe capture`: guided recording of real gestures (still, push, hold & slide, fist, swipes), one
/// labeled .caf + .json per step, so detection can be tuned on the user's actual hand instead of a model.
struct CaptureCommand {
    struct Step {
        let label: String
        let title: String
        let instructions: String
        let seconds: Double
        let layout: PilotLayout
    }

    static let single = PilotLayout.single(19_000)
    static let stereo = PilotLayout.stereo(left: 18_750, right: 19_250)

    /// Which script to run: the standard gesture capture or the taps-vs-fists one.
    var steps: [Step] = Self.gestureSteps
    var title = "Wave gesture capture"

    /// Things that must NOT grab (table and laptop taps, drumming) next to real fists, on the two tones the
    /// app uses with swipes on, so the grab detector can learn the difference.
    static let tapSteps: [Step] = [
        Step(label: "taps-table", title: "Tap the table",
             instructions: "Tap the table next to the laptop with your fingertips, about 8 times — some soft, some hard.",
             seconds: 14, layout: stereo),
        Step(label: "fist", title: "Fists",
             instructions: """
                Hold your open hand up about 20 cm in front of the screen, then close it into a fist quickly and firmly.
                    Open it, wait about 2 seconds, repeat — 5 fists.
                """, seconds: 20, layout: stereo),
        Step(label: "taps-laptop", title: "Tap the laptop",
             instructions: "Tap the palm rest next to the trackpad (not the keys) a few times. Then rest both palms on it, lift them, rest again.",
             seconds: 12, layout: stereo),
        Step(label: "drum", title: "Drum and knock",
             instructions: "Drum your fingers on the table next to the laptop, then knock on the table twice with a knuckle.",
             seconds: 10, layout: stereo),
    ]

    static let gestureSteps: [Step] = [
        Step(label: "still", title: "Sit normally",
             instructions: "Hands in your lap or resting, away from the laptop. Don't type.", seconds: 6, layout: single),
        Step(label: "push", title: "Pushes",
             instructions: "Push your hand toward the screen and straight back, 4 times, about 2 s apart.", seconds: 10, layout: single),
        Step(label: "hold-slide", title: "Hold, then slide",
             instructions: """
                Raise an open hand ~20 cm in front of the screen and HOLD IT STILL for 2 s.
                    Then SLOWLY move it ~5 cm closer (about 2 s), hold, then ~5 cm back. Repeat until the timer ends.
                """, seconds: 14, layout: single),
        Step(label: "fist", title: "Fist",
             instructions: """
                Raise an open hand ~20 cm in front of the screen, hold still 2 s, then close it into a fist.
                    Lower your hand, raise it again, repeat — 3 or 4 fists in total.
                """, seconds: 16, layout: single),
        Step(label: "swipe", title: "Swipes (two tones)",
             instructions: """
                Swipe your hand across the laptop 15–30 cm in front of the screen:
                    left → right, pause 2 s, right → left, pause 2 s … 3 times each.
                """, seconds: 16, layout: stereo),
    ]

    func run() async -> Int32 {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let dir = RecordingWriter.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("Captures/\(stamp.string(from: Date()))", isDirectory: true)

        // One engine at a time: quit the menu bar app while capturing, reopen it afterwards.
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.wave.Wave")
        let appURL = running.first?.bundleURL
        if !running.isEmpty {
            print("Quitting the Wave app during the capture (it reopens afterwards)…")
            running.forEach { $0.terminate() }
            for _ in 0..<40 where !NSRunningApplication.runningApplications(withBundleIdentifier: "local.wave.Wave").isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer {
            if let appURL {
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = [appURL.path]
                try? open.run()
                open.waitUntilExit()
                print("Reopened Wave.")
            }
        }

        print(Term.bold(title) + "  — \(steps.count) short steps, about a minute in total.")
        print("Each step records raw microphone audio to \(dir.path) (stays on your Mac).")
        print("""

            HOW IT WORKS — for every step:
              1. Read what to do.
              2. Press Return (click this window first if your typing doesn't reach it).
              3. Wait for 3… 2… 1… then ● GO.
              4. Do it until the countdown reaches 0 and it says ✓ saved.
            Keep your hands off the keyboard and trackpad while a step is recording.

            """)

        let printer = DetectCommand.Printer()
        printer.showRejected = false
        let engine = SonarEngine { printer.handle($0) }
        var settings = EngineSettings()
        var current: PilotLayout?
        var saved = 0

        for (i, step) in steps.enumerated() {
            if wave_stop_requested() { break }
            print(Term.bold("Step \(i + 1)/\(steps.count): \(step.title)  (\(Int(step.seconds)) s)"))
            print("    " + step.instructions)
            if isatty(STDIN_FILENO) != 0 {
                print("    Press Return to start…", terminator: "")
                fflush(stdout)
                _ = readLine()
            }
            if current != step.layout {
                settings.layout = step.layout
                if current == nil { engine.start(settings) } else { engine.update(settings) }
                current = step.layout
                try? await Task.sleep(nanoseconds: 1_200_000_000)  // engine (re)start + baseline warm-up
            }
            for n in [3, 2, 1] {
                print("    \(n)…")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            engine.startRecording(directory: dir, label: step.label)
            let end = Date().addingTimeInterval(step.seconds)
            while Date() < end && !wave_stop_requested() {
                print("\r\u{1B}[2K    ● GO — do it now: \(Int(end.timeIntervalSinceNow.rounded(.up))) s left", terminator: "")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            engine.stopRecording()
            try? await Task.sleep(nanoseconds: 300_000_000)
            print("\r\u{1B}[2K    ✓ saved \(step.label) — stop.\n")
            saved += 1
        }
        engine.stopAndWait()
        print(saved == steps.count
              ? Term.bold("Done — \(saved) recordings in \(dir.path)")
              : "Stopped after \(saved) recordings in \(dir.path)")
        print("Wave reopens now. Recordings are in the folder above (replay them with: make replay FILE=…).")
        return 0
    }
}
