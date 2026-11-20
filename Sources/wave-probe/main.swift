import Foundation
import WaveCore
import WaveRT

let usage = """
    wave-probe — M0 feasibility probe for Wave (ultrasonic Doppler gestures)

    USAGE
      wave-probe devices
          Machine + audio hardware report. Plays and records nothing.

      wave-probe speakers [--volume PCT | --mute]
          Shows or sets the built-in speakers' own volume/mute, without changing your default output.

      wave-probe sweep [options]
          Steps the pilot through 17–22.5 kHz: level, noise floor, SNR and Doppler visibility.
          --start HZ        first frequency (17000)
          --end HZ          last frequency (22500)
          --step HZ         step (250)
          --amplitude DBFS  pilot level, digital (-20)
          --wave SEC        seconds of waving per frequency in pass 2 (2.5)
          --skip-wave       pass 1 only (no Doppler test)
          --rate HZ         temporarily switch the mic to this sample rate (restored afterwards)
          --speaker-rate HZ temporarily switch the speakers to this sample rate (restored afterwards)
          --out PATH        Markdown report (wave-probe-report.md)
          --ignore-volume   run even if the speakers are muted (checks the capture path only)

      wave-probe live [options]
          Live scrolling spectrogram around the pilot(s). Ctrl-C to stop.
          --freq HZ         pilot frequency; repeat for several (20000)
          --stereo          first --freq on the left speaker, second on the right
          --amplitude DBFS  pilot level (-20)
          --span BINS       bins shown each side of the pilot (auto)
          --range DB        colour range above the noise floor (60)
          --duration SEC    stop automatically
          --ascii           characters instead of colours
          --rate HZ         temporarily switch the mic to this sample rate
          --ignore-volume   run even if the speakers are muted

    Debug (both commands): --output-uid UID / --input-uid UID use other devices (UIDs from `devices`),
    e.g. a loopback device to test the pipeline silently.

    The pilot always plays on the MacBook's built-in speakers and is captured from the built-in mic,
    whatever your default devices are. Audio is analysed in memory and never written to disk.
    """

struct Arguments {
    var command: String?
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    static let flagNames: Set<String> = ["skip-wave", "stereo", "ascii", "ignore-volume", "mute", "help"]

    init(_ args: [String]) throws {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-h" { flags.insert("help"); i += 1; continue }
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if Self.flagNames.contains(name) {
                    flags.insert(name)
                } else {
                    guard i + 1 < args.count else { throw ProbeError("--\(name) needs a value") }
                    values[name, default: []].append(args[i + 1])
                    i += 1
                }
            } else if command == nil {
                command = a
            } else {
                throw ProbeError("unexpected argument '\(a)'")
            }
            i += 1
        }
    }

    func double(_ name: String) throws -> Double? {
        guard let s = values[name]?.last else { return nil }
        guard let v = Double(s) else { throw ProbeError("--\(name) expects a number, got '\(s)'") }
        return v
    }

    func doubles(_ name: String) throws -> [Double] {
        try (values[name] ?? []).map {
            guard let v = Double($0) else { throw ProbeError("--\(name) expects a number, got '\($0)'") }
            return v
        }
    }

    func checkKnown(_ allowed: Set<String>) throws {
        for key in values.keys where !allowed.contains(key) { throw ProbeError("unknown option --\(key)") }
        for flag in flags where !allowed.contains(flag) && flag != "help" { throw ProbeError("unknown option --\(flag)") }
    }
}

func ensureMicrophoneAccess() async -> Bool {
    if await MicCapture.requestPermission() { return true }
    print("""
        ✗ Microphone access is \(Environment.permissionName(MicCapture.permission)) for this terminal app.
          System Settings → Privacy & Security → Microphone → enable your terminal (Terminal, iTerm, …),
          then quit and reopen the terminal.
        """)
    return false
}

wave_install_stop_signal_handlers()

let exitCode: Int32
do {
    let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
    switch args.command {
    case "devices":
        try args.checkKnown([])
        exitCode = DevicesCommand.run()

    case "speakers":
        try args.checkKnown(["volume", "mute", "output-uid"])
        exitCode = try SpeakersCommand.run(
            volumePercent: try args.double("volume"), mute: args.flags.contains("mute"),
            uid: args.values["output-uid"]?.last)

    case "sweep":
        try args.checkKnown(["start", "end", "step", "amplitude", "wave", "skip-wave", "rate", "speaker-rate", "out", "ignore-volume", "output-uid", "input-uid"])
        var o = SweepCommand.Options()
        if let v = try args.double("start") { o.start = v }
        if let v = try args.double("end") { o.end = v }
        if let v = try args.double("step") { o.step = max(10, v) }
        if let v = try args.double("amplitude") { o.amplitudeDB = min(0, v) }
        if let v = try args.double("wave") { o.waveSeconds = max(0.5, v) }
        if let v = args.values["out"]?.last { o.out = v }
        o.micRate = try args.double("rate")
        o.speakerRate = try args.double("speaker-rate")
        o.skipWave = args.flags.contains("skip-wave")
        o.overrides = DeviceOverrides(outputUID: args.values["output-uid"]?.last, inputUID: args.values["input-uid"]?.last)
        o.ignoreVolume = args.flags.contains("ignore-volume")
        guard try Environment.speakerPreflight(o.overrides, ignoreVolume: o.ignoreVolume) else { exit(2) }
        exitCode = await ensureMicrophoneAccess() ? try SweepCommand(options: o).run() : 3

    case "live":
        try args.checkKnown(["freq", "stereo", "amplitude", "span", "range", "duration", "ascii", "rate", "speaker-rate", "ignore-volume", "output-uid", "input-uid"])
        var o = LiveCommand.Options()
        let freqs = try args.doubles("freq")
        if !freqs.isEmpty { o.frequencies = Array(freqs.prefix(ToneSet.capacity)) }
        if let v = try args.double("amplitude") { o.amplitudeDB = min(0, v) }
        if let v = try args.double("span") { o.span = max(4, Int(v)) }
        if let v = try args.double("range") { o.rangeDB = max(10, v) }
        o.duration = try args.double("duration")
        o.micRate = try args.double("rate")
        o.speakerRate = try args.double("speaker-rate")
        o.stereo = args.flags.contains("stereo")
        o.overrides = DeviceOverrides(outputUID: args.values["output-uid"]?.last, inputUID: args.values["input-uid"]?.last)
        o.ignoreVolume = args.flags.contains("ignore-volume")
        o.ascii = args.flags.contains("ascii") || !Term.isTTY
        guard try Environment.speakerPreflight(o.overrides, ignoreVolume: o.ignoreVolume) else { exit(2) }
        exitCode = await ensureMicrophoneAccess() ? try LiveCommand(options: o).run() : 3

    case nil where args.flags.contains("help"), "help":
        print(usage)
        exitCode = 0

    default:
        print(usage)
        exitCode = 64
    }
} catch is Interrupted {
    print("\nInterrupted.")
    exitCode = 130
} catch {
    print("✗ \(error)")
    exitCode = 1
}
exit(exitCode)
