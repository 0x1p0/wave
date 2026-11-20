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

    static let steps: [Step] = [
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

        print(Term.bold("Wave gesture capture") + "  — \(Self.steps.count) short steps, about a minute in total.")
        print("Each step records raw microphone audio to \(dir.path) (stays on your Mac).\n")

        let printer = DetectCommand.Printer()
        let engine = SonarEngine { printer.handle($0) }
        var settings = EngineSettings()
        var current: PilotLayout?
        var saved = 0

        for (i, step) in Self.steps.enumerated() {
            if wave_stop_requested() { break }
            print(Term.bold("Step \(i + 1)/\(Self.steps.count): \(step.title)  (\(Int(step.seconds)) s)"))
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
            print("    ● GO")
            engine.startRecording(directory: dir, label: step.label)
            let end = Date().addingTimeInterval(step.seconds)
            while Date() < end && !wave_stop_requested() {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            engine.stopRecording()
            try? await Task.sleep(nanoseconds: 300_000_000)
            print("\r\u{1B}[2K    ✓ saved \(step.label)\n")
            saved += 1
        }
        engine.stopAndWait()
        print(saved == Self.steps.count
              ? Term.bold("Done — \(saved) recordings in \(dir.path)")
              : "Stopped after \(saved) recordings in \(dir.path)")
        print("Tell Claude “captured”.")
        return 0
    }
}
