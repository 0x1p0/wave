import Foundation
import WaveCore

/// `wave-probe live`: plays the pilot(s) and prints a scrolling spectrogram of the band around each one.
/// Each line is ~43 ms. Motion toward the screen shows up right of the pilot, away shows up left.
struct LiveCommand {
    struct Options {
        var frequencies: [Double] = [20_000]
        var amplitudeDB = -20.0
        var stereo = false
        var span: Int?
        var rangeDB = 60.0
        var duration: Double?
        var ascii = false
        var micRate: Double?
        var ignoreVolume = false
        var overrides = DeviceOverrides()
    }

    let options: Options
    let framesPerLine = 4

    func run() throws -> Int32 {
        let speakers = try options.overrides.speakers()
        let spk = Environment.speakerState(speakers)
        if let warning = spk.warning { print("! \(warning)") }

        let engine = try ProbeEngine(amplitudeDB: options.amplitudeDB, micRate: options.micRate, overrides: options.overrides)
        defer { engine.shutdown() }
        let bands = options.frequencies.map(engine.band)
        let tones: [PilotTone] = bands.enumerated().map { i, b in
            guard options.stereo, bands.count >= 2 else { return PilotTone(frequency: b.pilotHz) }
            return i % 2 == 0
                ? PilotTone(frequency: b.pilotHz, leftGain: 1, rightGain: 0)
                : PilotTone(frequency: b.pilotHz, leftGain: 0, rightGain: 1)
        }
        let textWidth = 30
        let span = options.span ?? max(10, min(40, ((Term.columns - 2) / bands.count - textWidth) / 2))

        print(Term.bold("Wave live view") + "  \(engine.speakers.name) → \(engine.mic.name) (\(engine.mic.inputChannels) ch @ \(Int(engine.sampleRate)) Hz), \(spk.summary)")
        try engine.start(tones: tones)
        try engine.settle(0.3)

        print("Measuring the still-hand baseline — keep still for 1 s…")
        var baseline = [Float]()
        var n: Float = 0
        try engine.collect(frames: engine.frames(forSeconds: 1)) { spec in
            if baseline.isEmpty { baseline = spec } else { for k in spec.indices { baseline[k] += spec[k] } }
            n += 1
        }
        for k in baseline.indices { baseline[k] /= n }
        let floors = bands.map { b in b.measure(baseline).sidebandMedian.dB }
        let floorDB = Double(Stats.median(floors))
        if engine.heardDigitalSilence {
            throw ProbeError("The microphone delivered pure digital silence — check Microphone access for this terminal app.")
        }

        // Legend
        for (i, b) in bands.enumerated() {
            let base = b.measure(baseline)
            let side = options.stereo && bands.count >= 2 ? (i % 2 == 0 ? " (left speaker)" : " (right speaker)") : ""
            print("  Pilot \(fmt(b.pilotHz, 1)) Hz\(side): level \(fmt(base.pilotPower.dB)) dBFS, floor \(fmt(base.sidebandMedian.dB)) dB/bin, "
                  + "SNR \(fmt(base.pilotPower.dB - base.sidebandMedian.dB)) dB")
        }
        let vmax = bands[0].velocity(forBinOffset: Double(span))
        print("  Columns: ±\(span) bins = ±\(Int(Double(span) * engine.analyzer.binWidth)) Hz ≈ ±\(fmt(vmax, 1)) m/s.  "
              + "Left of centre = hand moving AWAY, right = TOWARD.  Colour: \(Int(floorDB)) … \(Int(floorDB + options.rangeDB)) dB.")
        print("  ▲/▼ = sideband energy vs baseline, v = estimated hand speed (+ toward). Ctrl-C to stop.\n")
        let header = bands.map { _ in
            let half = String(repeating: "─", count: max(0, span - 6))
            return "away " + half + "┤pilot├" + half + " toward" + String(repeating: " ", count: max(0, textWidth - 10))
        }.joined(separator: " ")
        print(Term.dim(header))

        // Stream
        var maxSpec = [Float](repeating: 0, count: engine.analyzer.binCount)
        var sumSpec = [Float](repeating: 0, count: engine.analyzer.binCount)
        var count = 0
        let totalFrames = options.duration.map { engine.frames(forSeconds: $0) } ?? Int.max
        do {
            try engine.collect(frames: totalFrames) { spec in
                for k in spec.indices {
                    maxSpec[k] = max(maxSpec[k], spec[k])
                    sumSpec[k] += spec[k]
                }
                count += 1
                guard count == framesPerLine else { return }
                var line = ""
                for b in bands {
                    line += renderBand(b, maxSpec: maxSpec, sumSpec: sumSpec, frames: count, baseline: baseline,
                                       span: span, floorDB: floorDB, textWidth: textWidth)
                    line += " "
                }
                Term.write(line + "\n")
                for k in maxSpec.indices { maxSpec[k] = 0; sumSpec[k] = 0 }
                count = 0
            }
        } catch is Interrupted {
            print("\nStopping (fading out)…")
        }
        return 0
    }

    private func renderBand(
        _ b: PilotBand, maxSpec: [Float], sumSpec: [Float], frames: Int, baseline: [Float],
        span: Int, floorDB: Double, textWidth: Int
    ) -> String {
        var cells = ""
        for k in (b.pilotBin - span)...(b.pilotBin + span) {
            guard k >= 0, k < maxSpec.count else { cells += " "; continue }
            let t = pow((Double(maxSpec[k].dB) - floorDB) / options.rangeDB, 0.8)
            cells += Term.cell(k == b.pilotBin ? 1 : t, ascii: options.ascii)
        }
        // Metrics on the mean spectrum of this line.
        let inv = 1 / Float(frames)
        var up: Float = 0, down: Float = 0, upBase: Float = 0, downBase: Float = 0
        var weighted = 0.0, total = 0.0
        for k in b.upperRange {
            up += sumSpec[k] * inv; upBase += baseline[k]
            let e = Double(max(0, sumSpec[k] * inv - 2 * baseline[k])); weighted += e * Double(k - b.pilotBin); total += e
        }
        for k in b.lowerRange {
            down += sumSpec[k] * inv; downBase += baseline[k]
            let e = Double(max(0, sumSpec[k] * inv - 2 * baseline[k])); weighted += e * Double(k - b.pilotBin); total += e
        }
        let upDB = (up / max(upBase, 1e-20)).dB
        let downDB = (down / max(downBase, 1e-20)).dB
        var text = " ▲\(pad(fmt(upDB, 0, sign: true), 3)) ▼\(pad(fmt(downDB, 0, sign: true), 3))"
        if total > 0, max(upDB, downDB) > 3 {
            text += "  v" + pad(fmt(b.velocity(forBinOffset: weighted / total), 2, sign: true), 6)
        }
        return cells + text + String(repeating: " ", count: max(0, textWidth - text.count))
    }
}
