import Foundation
import WaveCore

/// `wave-probe replay FILE.caf`: runs a debug recording through the pipeline (as fast as possible) so
/// detector changes can be compared on exactly the same audio.
struct ReplayCommand {
    struct Options {
        var file: String
        var sensitivity: Double?
        var frequency: Double?
        var csv: String?
        var config: DetectorConfig?
        var noHover = false
        var showRejected = true
        /// Pull unmapped in the app: pulls only count while hovering.
        var noPull = false
        var noGrab = false
        /// Writes every event (accepted and rejected) as JSON lines here.
        var json: String?
    }

    let options: Options

    func run() throws -> Int32 {
        let url = URL(fileURLWithPath: (options.file as NSString).expandingTildeInPath)
        let recording = try LoadedRecording.load(url)
        var detector = options.config ?? recording.metadata?.detector ?? DetectorConfig()
        if let s = options.sensitivity { detector.sensitivity = s }
        let pilots = options.frequency.map { [$0] }

        print(Term.bold("Replay \(url.lastPathComponent)"))
        print(String(format: "  %.1f s, %d ch @ %.0f Hz", recording.duration, recording.channels.count, recording.sampleRate))
        if let m = recording.metadata {
            var line = "  pilots \(m.pilots.map { String(format: "%.1f", $0) }.joined(separator: ", ")) Hz"
            if let a = m.amplitudeDBFS { line += String(format: ", pilot %.1f dBFS", a) }
            if let g = m.speakerGainDB { line += String(format: ", speakers %.1f dB", g) }
            line += ", \(m.inputTimes.count) input events"
            if let label = m.label { line += ", label \"\(label)\"" }
            print(line)
        } else {
            print("  (no sidecar JSON: assuming a 19 kHz pilot and no keyboard input)")
        }
        print("  detector sensitivity \(detector.sensitivity) (on \(fmt(detector.effectiveOnDB)) dB, peak ≥ \(fmt(detector.effectiveMinPeakDB)) dB)\n")

        var csv: FileHandle?
        if let path = options.csv {
            FileManager.default.createFile(atPath: path, contents: nil)
            csv = FileHandle(forWritingAtPath: path)
            csv?.write(Data("time,pilot_db,toward_db,away_db,reference_db,velocity,reflection_db,quiet,micro_db,displacement_mm,phase_velocity,audible_db\n".utf8))
        }
        var controlLines: [String] = []
        var dial = 0.0
        var interaction = InteractionConfig()
        if options.noHover { interaction.dialEnabled = false }
        if options.noPull { interaction.pullEnabled = false }
        if options.noGrab { interaction.grabEnabled = false }
        let result = Replay.run(recording, pilots: pilots, detector: detector, interaction: interaction) { out in
            let t = out.frames.last?.time ?? 0
            for c in out.controls {
                switch c {
                case .ready(let i): dial = 0; controlLines.append(String(format: "%8.2f s  ✋ ready (target %d)", t, i))
                case .targetChanged(let i): controlLines.append(String(format: "%8.2f s  ✋ target → %d", t, i))
                case .adjust(_, let d):
                    dial += d
                    controlLines.append(String(format: "%8.2f s  %@", t, d > 0 ? "▲ up" : "▼ down"))
                case .ended: controlLines.append(String(format: "%8.2f s  ✋ ended (dial %+.0f %%)", t, dial * 100))
                }
            }
            guard let csv else { return }
            var rows = ""
            for frame in out.frames {
                let f = frame.bands[0]
                rows += String(format: "%.4f,%.2f,%.2f,%.2f,%.2f,%.3f,%.2f,%d,%.2f,%.3f,%.4f,%.2f\n",
                               f.time, f.pilotDB, f.towardDB, f.awayDB, f.referenceDB, f.velocity, f.reflectionDB, f.quiet ? 1 : 0,
                               f.microDB, f.displacement * 1000, f.basebandVelocity, f.audibleDB)
            }
            csv.write(Data(rows.utf8))
        }
        try? csv?.close()

        if let path = options.json {
            let encoder = JSONEncoder()
            let lines = result.events.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        let shown = options.showRejected ? result.events : result.events.filter(\.isAccepted)
        for e in shown { print(String(format: "%8.2f s  ", e.end) + e.summary) }
        controlLines.forEach { print($0) }
        let accepted = result.events.filter(\.isAccepted).count
        print("\n\(accepted) gesture(s) accepted, \(result.events.count - accepted) candidate(s) rejected, \(result.frames) frames.")
        if let live = recording.metadata?.liveEvents {
            print("Live detector at recording time: \(live.filter(\.isAccepted).count) accepted, \(live.filter { !$0.isAccepted }.count) rejected.")
        }
        if let path = options.csv { print("Features → \(path)") }
        return 0
    }
}
