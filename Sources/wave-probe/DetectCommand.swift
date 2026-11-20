import Foundation
import os
import WaveCore
import WaveRT

/// `wave-probe detect`: live push detection in the terminal (no GUI).
struct DetectCommand {
    struct Options {
        var frequency = 19_000.0
        var amplitudeDB = -8.0
        var sensitivity = 0.5
        var duration: Double?
        var record = false
        var label: String?
        var directory = RecordingWriter.defaultDirectory
        var config: DetectorConfig?
    }

    let options: Options

    /// Engine-queue-only printer state (the engine calls back on one serial queue).
    private final class Printer: @unchecked Sendable {
        var lastStatus: EngineStatus?
        var lastMeter = 0.0
        var saved: URL?
        var dialTotal = 0.0
        let tty = isatty(STDOUT_FILENO) != 0

        func handle(_ out: EngineOutput) {
            if out.status != lastStatus {
                clearMeter()
                print("● \(out.status.text)" + (out.amplitudeDBFS.map { String(format: "  (pilot %.1f dBFS", $0) + (out.speakerGainDB.map { String(format: ", speakers %.1f dB)", $0) } ?? ")") } ?? ""))
                lastStatus = out.status
            }
            for e in out.events {
                clearMeter()
                print(String(format: "%8.2f s  ", e.end) + e.summary)
            }
            for c in out.controls {
                switch c {
                case .ready(let i):
                    clearMeter(); dialTotal = 0
                    print("          ✋ READY  (dial target \(i): slide slowly closer/farther, or close your hand to grab)")
                case .targetChanged(let i):
                    clearMeter(); print("          ✋ dial target → \(i)")
                case .adjust(_, let d):
                    dialTotal += d
                case .ended:
                    clearMeter()
                    print(String(format: "          ✋ ended  (dial total %+.0f %%)", dialTotal * 100))
                }
            }
            if let url = out.savedRecording { saved = url }
            guard tty, let f = out.frames.last?.bands.first else { return }
            let now = Date().timeIntervalSince1970
            guard now - lastMeter > 0.1 else { return }
            lastMeter = now
            let idle = out.inputIdle.map { String(format: "idle %4.1f s", $0) } ?? ""
            let line = String(format: "  ▲%+5.1f ▼%+5.1f ref %+5.1f dB  v %+5.2f m/s  micro %+5.1f dB  phase %+5.1f cm/s  %@",
                              f.towardDB, f.awayDB, f.referenceDB, f.velocity, f.microDB, f.basebandVelocity * 100, idle)
            fputs("\r\u{1B}[2K" + line, stdout)
            fflush(stdout)
        }

        private func clearMeter() {
            if tty { fputs("\r\u{1B}[2K", stdout) }
        }
    }

    func run() -> Int32 {
        var settings = EngineSettings()
        settings.pilots = [options.frequency]
        settings.level.referenceAmplitudeDBFS = options.amplitudeDB
        settings.detector = options.config ?? DetectorConfig()
        settings.detector.sensitivity = options.sensitivity

        let printer = Printer()
        let engine = SonarEngine { printer.handle($0) }
        print(Term.bold("Wave — live push detection") + "  pilot \(Int(options.frequency)) Hz, sensitivity \(options.sensitivity)")
        print("Push = move your hand toward the screen and straight back (~0.2–0.7 s). Typing/trackpad pauses detection for 0.8 s.")
        print("Ctrl-C to stop.\n")
        engine.start(settings)
        if options.record {
            engine.startRecording(directory: options.directory, label: options.label)
            print("Recording raw mic audio to \(options.directory.path) (debug, opt-in).")
        }
        let end = options.duration.map { Date().addingTimeInterval($0) }
        while !wave_stop_requested() {
            if let end, Date() >= end { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        engine.stopAndWait()
        Thread.sleep(forTimeInterval: 0.05)
        print()
        if let saved = printer.saved {
            print("Saved \(saved.path)")
            print("Replay: wave-probe replay \"\(saved.path)\"")
        }
        if case .failed(let reason) = printer.lastStatus ?? .stopped { print("✗ \(reason)"); return 1 }
        return 0
    }
}
