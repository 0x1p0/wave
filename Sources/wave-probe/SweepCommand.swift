import Foundation
import WaveCore

/// `wave-probe sweep`: steps the pilot through 17–22.5 kHz and measures, per frequency, the received
/// level, noise floor, SNR and whether a waving hand produces visible Doppler sidebands.
///
/// Pass 1 (hands still): pilot off → noise floor; pilot on → level and sideband floor.
/// Pass 2 (waving):      pilot on → sideband energy while you wave, compared with pass 1.
struct SweepCommand {
    struct Options {
        var start = 17_000.0
        var end = 22_500.0
        var step = 250.0
        var amplitudeDB = -20.0
        var noiseSeconds = 0.6
        var stillSeconds = 1.0
        var waveSeconds = 2.5
        var skipWave = false
        var out = "wave-probe-report.md"
        var micRate: Double?
        var speakerRate: Double?
        var ignoreVolume = false
        var overrides = DeviceOverrides()
    }

    struct Row {
        let requestedHz: Double
        let band: PilotBand
        var noise: Float = 0        // per-bin power, pilot off (median)
        var level: Float = 0        // pilot-bin power, pilot on, still (median)
        var skirt: Float = 0        // per-bin sideband power, pilot on, still (median)
        var stillUpper: Float = 0   // mean summed sideband energy, still
        var stillLower: Float = 0
        var waveUpper: Float?       // 95th-percentile summed sideband energy while waving
        var waveLower: Float?

        var levelDB: Float { level.dB }
        var noiseDB: Float { noise.dB }
        var skirtDB: Float { skirt.dB }
        var snrDB: Float { levelDB - noiseDB }
        var excessUpDB: Float? { waveUpper.map { ($0 / max(stillUpper, 1e-20)).dB } }
        var excessDownDB: Float? { waveLower.map { ($0 / max(stillLower, 1e-20)).dB } }
        var minExcessDB: Float? {
            guard let u = excessUpDB, let d = excessDownDB else { return nil }
            return min(u, d)
        }
        /// Both sidebands (toward and away) rise ≥ 6 dB above the still-hand level.
        var dopplerVisible: Bool? {
            minExcessDB.map { $0 >= SweepCommand.visibleThresholdDB && snrDB >= SweepCommand.minDopplerSNR }
        }
        /// Sidebands rose but there is no pilot to reflect: broadband noise during waving, not Doppler.
        var noiseBurst: Bool { (minExcessDB ?? 0) >= SweepCommand.visibleThresholdDB && snrDB < SweepCommand.minDopplerSNR }
        var dopplerMark: String {
            guard let visible = dopplerVisible, let ex = minExcessDB else { return "–" }
            if visible { return ex >= SweepCommand.strongThresholdDB ? "y" : "y (weak)" }
            return noiseBurst ? "n*" : "n"
        }
    }

    static let visibleThresholdDB: Float = 6
    static let strongThresholdDB: Float = 10
    static let minDopplerSNR: Float = 10
    static let inaudibleFromHz = 18_500.0
    static let goodSNR: Float = 20

    let options: Options

    func run() throws -> Int32 {
        let machine = MachineInfo.current()
        let speakers = try options.overrides.speakers()
        let spk = Environment.speakerState(speakers)

        let engine = try ProbeEngine(amplitudeDB: options.amplitudeDB, micRate: options.micRate, speakerRate: options.speakerRate, overrides: options.overrides)
        defer { engine.shutdown() }

        let nyquistLimit = engine.sampleRate / 2 - Double(32 + 2) * engine.analyzer.binWidth
        var rows: [Row] = stride(from: options.start, through: options.end + 0.1, by: options.step)
            .filter { $0 < nyquistLimit }
            .map { Row(requestedHz: $0, band: engine.band($0)) }
        guard !rows.isEmpty else { throw ProbeError("No frequencies to test below \(Int(nyquistLimit)) Hz.") }

        print(Term.bold("Wave M0 — ultrasonic feasibility sweep"))
        print("  \(machine.summary)")
        print("  Pilot  → \(engine.speakers.name) (\(engine.speakers.outputChannels) ch @ \(Int(engine.pilot.sampleRate)) Hz), \(spk.summary)")
        print("  Capture← \(engine.mic.name) (\(engine.mic.inputChannels) ch @ \(Int(engine.sampleRate)) Hz; supports \(engine.mic.sampleRatesDescription)), mic mode \(Environment.micModeName())")
        print("  Pilot amplitude \(fmt(options.amplitudeDB)) dBFS, FFT \(engine.analyzer.fftSize)/hop \(engine.hop) → \(fmt(engine.analyzer.binWidth, 2)) Hz bins")
        print("  \(rows.count) frequencies, \(Int(rows.first!.requestedHz))–\(Int(rows.last!.requestedHz)) Hz in \(Int(options.step)) Hz steps")
        if let warning = spk.warning { print("\n! \(warning)") }

        try engine.start(tones: [])

        // ---- Pass 1: still ----------------------------------------------------------------
        print()
        print(Term.bold("Pass 1/\(options.skipWave ? 1 : 2): keep still."))
        print("  Hands in your lap, away from the laptop, and stay quiet. You may hear faint chirps below ~18 kHz.")
        waitForReturn("  Press Return to start pass 1…")
        let p1 = Double(rows.count) * (0.15 + 0.2 + options.noiseSeconds + options.stillSeconds + 0.2)
        print("  (about \(Int(p1)) s)")
        print(Term.dim("  " + pad("Hz", 7) + pad("level dB", 11) + pad("noise dB", 11) + pad("SNR dB", 9) + pad("skirt dB", 11)))
        engine.resetPeak()
        for i in rows.indices {
            let band = rows[i].band
            engine.setTones([])
            try engine.settle(0.15)
            var noise: [Float] = []
            try engine.collect(frames: engine.frames(forSeconds: options.noiseSeconds)) { spec in
                noise.append(band.measure(spec).sidebandMedian)
            }
            engine.setTones([PilotTone(frequency: band.pilotHz)])
            try engine.settle(0.2)
            var level: [Float] = [], skirt: [Float] = [], up: [Float] = [], down: [Float] = []
            try engine.collect(frames: engine.frames(forSeconds: options.stillSeconds)) { spec in
                let m = band.measure(spec)
                level.append(m.pilotPower); skirt.append(m.sidebandMedian)
                up.append(m.upperEnergy); down.append(m.lowerEnergy)
            }
            rows[i].noise = Stats.median(noise)
            rows[i].level = Stats.median(level)
            rows[i].skirt = Stats.median(skirt)
            rows[i].stillUpper = Stats.mean(up)
            rows[i].stillLower = Stats.mean(down)
            let r = rows[i]
            print("  " + pad("\(Int(r.requestedHz))", 7) + pad(fmt(r.levelDB), 11) + pad(fmt(r.noiseDB), 11)
                  + pad(fmt(r.snrDB), 9) + pad(fmt(r.skirtDB), 11))
        }
        engine.setTones([])
        if engine.heardDigitalSilence {
            throw ProbeError("""
                The microphone delivered (near-)silence. Microphone access is probably denied for \
                this terminal app: System Settings → Privacy & Security → Microphone.
                """)
        }

        // ---- Pass 2: waving ---------------------------------------------------------------
        if !options.skipWave {
            print()
            print(Term.bold("Pass 2/2: wave."))
            print("""
                  Hold one hand 10–30 cm in front of the screen and keep moving it toward the screen and
                  back (like a slow push, ~2 per second) for the whole pass. Don't touch the laptop.
                """)
            waitForReturn("  Press Return, then start waving…")
            for n in [3, 2, 1] {
                print("  \(n)…")
                try engine.settle(1)
            }
            let p2 = Double(rows.count) * (0.2 + options.waveSeconds + 0.1)
            print("  WAVE! (about \(Int(p2)) s — keep going until it says stop)")
            print(Term.dim("  " + pad("Hz", 7) + pad("▲ toward", 11) + pad("▼ away", 10) + "  visible"))
            for i in rows.indices {
                let band = rows[i].band
                engine.setTones([PilotTone(frequency: band.pilotHz)])
                try engine.settle(0.2)
                var up: [Float] = [], down: [Float] = []
                try engine.collect(frames: engine.frames(forSeconds: options.waveSeconds)) { spec in
                    let m = band.measure(spec)
                    up.append(m.upperEnergy); down.append(m.lowerEnergy)
                }
                rows[i].waveUpper = Stats.percentile(up, 0.95)
                rows[i].waveLower = Stats.percentile(down, 0.95)
                let r = rows[i]
                print("  " + pad("\(Int(r.requestedHz))", 7) + pad(fmt(r.excessUpDB ?? 0, sign: true), 11)
                      + pad(fmt(r.excessDownDB ?? 0, sign: true), 10) + "  " + r.dopplerMark)
            }
            engine.setTones([])
            print(Term.bold("  STOP — you can rest your hand."))
        }
        engine.shutdown()

        // ---- Results ------------------------------------------------------------------------
        let report = Report(
            machine: machine, engine: engine, speakerSummary: spk.summary, options: options, rows: rows,
            droppedFrames: engine.capture.ring.droppedFrames)
        print()
        print(report.terminalTable())
        print()
        print(report.verdictText())
        let url = URL(fileURLWithPath: options.out)
        try report.markdown().write(to: url, atomically: true, encoding: .utf8)
        print()
        print("Report written to \(url.path)")
        return 0
    }

    private func waitForReturn(_ prompt: String) {
        guard isatty(STDIN_FILENO) != 0 else { return }
        print(prompt, terminator: "")
        fflush(stdout)
        _ = readLine()
    }
}

// MARK: - Report

struct Report {
    let machine: MachineInfo
    let engine: ProbeEngine
    let speakerSummary: String
    let options: SweepCommand.Options
    let rows: [SweepCommand.Row]
    let droppedFrames: Int64

    private var waved: Bool { rows.contains { $0.waveUpper != nil } }

    struct Recommendation {
        var verdict: String
        var details: [String]
    }

    private func score(_ r: SweepCommand.Row) -> Float { (r.minExcessDB ?? 0) + 0.1 * r.snrDB }

    func recommendation() -> Recommendation {
        let inaudible = rows.filter { $0.band.pilotHz >= SweepCommand.inaudibleFromHz }
        let usable = inaudible.filter { $0.snrDB >= SweepCommand.goodSNR && ($0.dopplerVisible ?? true) }
        var details: [String] = []

        guard let primary = usable.max(by: { score($0) < score($1) }) else {
            let bestSNR = inaudible.max { $0.snrDB < $1.snrDB }
            let bestDoppler = inaudible.compactMap { r in r.minExcessDB.map { (r, $0) } }.max { $0.1 < $1.1 }
            var verdict = "NOT FEASIBLE at this amplitude/volume: no frequency ≥ \(Int(SweepCommand.inaudibleFromHz)) Hz "
            verdict += waved
                ? "has SNR ≥ \(Int(SweepCommand.goodSNR)) dB *and* visible Doppler on both sides."
                : "has SNR ≥ \(Int(SweepCommand.goodSNR)) dB."
            if let b = bestSNR { details.append("Best SNR ≥ \(Int(SweepCommand.inaudibleFromHz)) Hz: \(Int(b.requestedHz)) Hz at \(fmt(b.snrDB)) dB.") }
            if let d = bestDoppler { details.append("Best Doppler: \(Int(d.0.requestedHz)) Hz at \(fmt(d.1, sign: true)) dB (needs ≥ +\(Int(SweepCommand.visibleThresholdDB)) dB).") }
            details.append("Before giving up: re-run with the speakers at ~50–75 % volume and/or --amplitude -10, and wave closer (10–15 cm).")
            return Recommendation(verdict: verdict, details: details)
        }

        let verdict = waved
            ? "FEASIBLE: the speakers and mic carry \(Int(SweepCommand.inaudibleFromHz / 1000))+ kHz cleanly and a waving hand shows clear Doppler sidebands."
            : "LIKELY FEASIBLE: good SNR above \(Int(SweepCommand.inaudibleFromHz)) Hz (Doppler not measured — run without --skip-wave)."
        details.append("Primary pilot (push detection): \(Int(primary.requestedHz)) Hz → \(fmt(primary.band.pilotHz, 2)) Hz bin-centred "
                       + "(SNR \(fmt(primary.snrDB)) dB" + (primary.minExcessDB.map { ", Doppler ≥ \(fmt($0, sign: true)) dB" } ?? "") + ").")

        var best: (SweepCommand.Row, SweepCommand.Row)?
        for a in usable { for b in usable where b.requestedHz - a.requestedHz >= 1000 {
            if best == nil || min(score(a), score(b)) > min(score(best!.0), score(best!.1)) { best = (a, b) }
        } }
        if let (a, b) = best {
            details.append("Stereo pair for swipes (M3): left \(Int(a.requestedHz)) Hz, right \(Int(b.requestedHz)) Hz (≥ 1 kHz apart so Doppler bands can't overlap).")
        } else {
            details.append("No second usable frequency ≥ 1 kHz away from the first: two-pilot swipes (M3) look doubtful.")
        }

        // Amplitude. If the still-hand sideband floor is (nearly) the pilot-off noise floor, Doppler visibility
        // scales 1:1 with pilot level. If it is well above, the floor rises with the pilot and level barely matters.
        if let minEx = primary.minExcessDB {
            let target: Float = 12
            let delta = Double(minEx - target)
            if primary.skirtDB - primary.noiseDB < 6 {
                if delta <= -1 {
                    let needed = min(-3, options.amplitudeDB - delta)
                    details.append("Amplitude: noise-limited and ~\(Int((-delta).rounded())) dB short of a \(Int(target)) dB Doppler margin. "
                                   + "Raise the pilot to ≈ \(fmt(needed, 0)) dBFS (we used \(fmt(options.amplitudeDB, 0))) or the speaker volume by the same amount.")
                } else if delta >= 3 {
                    details.append("Amplitude: ~\(Int(delta)) dB of spare Doppler margin; ≈ \(fmt(options.amplitudeDB - delta, 0)) dBFS should still work at this volume.")
                } else {
                    details.append("Amplitude: \(fmt(options.amplitudeDB, 0)) dBFS at this volume is about right; no headroom to lower it.")
                }
            } else if primary.skirtDB - primary.noiseDB < 12 {
                details.append("Amplitude: the sideband floor is partly set by the speaker/mic chain, so more level still helps "
                               + "but less than 1:1; Doppler margin \(fmt(minEx, sign: true)) dB at \(fmt(options.amplitudeDB, 0)) dBFS.")
            } else {
                details.append("Amplitude: the sideband floor is set by the speaker/mic chain (it rises with the pilot), so level changes "
                               + "barely affect Doppler visibility; Doppler margin \(fmt(minEx, sign: true)) dB.")
            }
        }
        if rows.contains(where: \.noiseBurst) {
            let hz = rows.filter(\.noiseBurst).map { "\(Int($0.requestedHz))" }.joined(separator: ", ")
            details.append("n* at \(hz) Hz: sideband energy rose with no usable pilot there, i.e. broadband noise while waving (clothing, rings…). "
                           + "The detector must reject this with a reference band away from the pilot.")
        }

        let audible = rows.filter { $0.band.pilotHz < SweepCommand.inaudibleFromHz && $0.snrDB >= SweepCommand.goodSNR }
        if !audible.isEmpty {
            details.append("17–18.5 kHz also works acoustically but is audible to many people (especially younger listeners), so it is excluded.")
        }
        let weak = rows.filter { $0.snrDB < 10 }.map { "\(Int($0.requestedHz))" }
        if !weak.isEmpty { details.append("Unusable (SNR < 10 dB): \(weak.joined(separator: ", ")) Hz.") }
        return Recommendation(verdict: verdict, details: details)
    }

    func verdictText() -> String {
        let r = recommendation()
        return ([Term.bold(r.verdict)] + r.details.map { "  • " + $0 }).joined(separator: "\n")
    }

    func terminalTable() -> String {
        var lines = [Term.bold(
            pad("Freq Hz", 8) + pad("Pilot Hz", 10) + pad("Level dB", 10) + pad("Noise dB", 10) + pad("SNR dB", 8)
                + pad("Skirt dB", 10) + pad("▲ dB", 8) + pad("▼ dB", 8) + pad("Doppler", 10))]
        for r in rows {
            lines.append(
                pad("\(Int(r.requestedHz))", 8) + pad(fmt(r.band.pilotHz, 1), 10) + pad(fmt(r.levelDB), 10)
                    + pad(fmt(r.noiseDB), 10) + pad(fmt(r.snrDB), 8) + pad(fmt(r.skirtDB), 10)
                    + pad(r.excessUpDB.map { fmt($0, sign: true) } ?? "–", 8)
                    + pad(r.excessDownDB.map { fmt($0, sign: true) } ?? "–", 8)
                    + pad(r.dopplerMark, 10))
        }
        return lines.joined(separator: "\n")
    }

    func markdown() -> String {
        let a = engine.analyzer
        let date = ISO8601DateFormatter().string(from: Date())
        var md = """
            # Wave M0 — ultrasonic feasibility probe

            Run \(date)

            | | |
            |---|---|
            | Machine | \(machine.summary) |
            | Pilot output | \(engine.speakers.name) — \(engine.speakers.outputChannels) ch @ \(Int(engine.pilot.sampleRate)) Hz, \(speakerSummary) |
            | Capture | \(engine.mic.name) — **\(engine.mic.inputChannels) ch** @ \(Int(engine.sampleRate)) Hz (supported rates: **\(engine.mic.sampleRatesDescription)**), mic mode \(Environment.micModeName()) |
            | Pilot amplitude | \(fmt(options.amplitudeDB)) dBFS digital, 50 ms raised-cosine fades, both channels |
            | Analysis | Hann, FFT \(a.fftSize), hop \(engine.hop) (\(fmt(a.binWidth, 2)) Hz bins, \(fmt(Double(engine.hop) / engine.sampleRate * 1000)) ms hop) |
            | Doppler band | pilot ± \(rows[0].band.innerBins)…\(rows[0].band.outerBins) bins = ± \(Int(Double(rows[0].band.innerBins) * a.binWidth))–\(Int(Double(rows[0].band.outerBins) * a.binWidth)) Hz |
            | Dropped frames | \(droppedFrames) |

            ## Results

            | Freq Hz | Pilot Hz | Level dBFS | Noise dB/bin | SNR dB | Skirt dB/bin | ▲ toward dB | ▼ away dB | Doppler visible |
            |---:|---:|---:|---:|---:|---:|---:|---:|:---:|

            """
        for r in rows {
            md += "| \(Int(r.requestedHz)) | \(fmt(r.band.pilotHz, 1)) | \(fmt(r.levelDB)) | \(fmt(r.noiseDB)) | \(fmt(r.snrDB)) | \(fmt(r.skirtDB)) | "
            md += "\(r.excessUpDB.map { fmt($0, sign: true) } ?? "–") | \(r.excessDownDB.map { fmt($0, sign: true) } ?? "–") | "
            md += "\(r.dopplerMark) |\n"
        }
        let rec = recommendation()
        md += "\n## Verdict\n\n**\(rec.verdict)**\n\n" + rec.details.map { "- \($0)" }.joined(separator: "\n") + "\n"
        md += """

            ## Columns

            - **Level** — power in the pilot's own FFT bin, pilot on, hands still (0 dBFS = full-scale sine).
            - **Noise** — median per-bin power across the Doppler band with the pilot **off**.
            - **SNR** — Level − Noise.
            - **Skirt** — median per-bin power across the Doppler band with the pilot **on**, hands still. If it is well above Noise, the speaker/mic chain adds distortion or phase noise around the pilot that Doppler has to beat.
            - **▲ / ▼** — 95th-percentile sideband energy while waving vs the still-hand mean, above (toward) and below (away) the pilot.
            - **Doppler visible** — y when both ▲ and ▼ are ≥ +\(Int(SweepCommand.strongThresholdDB)) dB, "y (weak)" for +\(Int(SweepCommand.visibleThresholdDB))…\(Int(SweepCommand.strongThresholdDB)) dB. \
            Requires SNR ≥ \(Int(SweepCommand.minDopplerSNR)) dB; `n*` = sidebands rose without a usable pilot (broadband noise during waving, not Doppler).

            """
        return md
    }
}
