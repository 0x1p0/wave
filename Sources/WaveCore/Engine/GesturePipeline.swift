import Foundation

/// One analysis frame (every hop, ~10.7 ms).
public struct PipelineFrame: Sendable {
    /// Stream time of the window's end, seconds.
    public var time: Double
    /// Features per pilot, in pilot order.
    public var bands: [BandFeatures]
    /// Spectrum around each pilot in dBFS (pilot ± displayHalfWidth bins, low → high), pilots concatenated.
    /// Empty unless `wantsDisplay` is set.
    public var display: [Float]
}

public struct PipelineOutput: Sendable {
    public var frames: [PipelineFrame] = []
    public var events: [GestureEvent] = []
    /// Hover interaction (ready, adjust, ended).
    public var controls: [ControlEvent] = []
    /// Hover state after this chunk (for live views).
    public var interactionPhase: InteractionDetector.Phase = .idle
    /// Largest absolute sample in this chunk (for silence detection).
    public var peak: Float = 0
}

/// Samples in → features + gesture events out. Synchronous and deterministic: the live engine, the
/// replay harness and the unit tests all drive this same object.
public final class GesturePipeline {
    public let sampleRate: Double
    public let channels: Int
    public let fftSize: Int
    public let hop: Int
    public let bands: [PilotBand]
    public let layout: PilotLayout
    public let displayHalfWidth: Int
    public var wantsDisplay = false
    public var detectorConfig: DetectorConfig {
        didSet {
            detectors.forEach { $0.config = detectorConfig }
            pullDetector?.config = detectorConfig
            interaction.detector = detectorConfig
        }
    }
    public var fusionConfig: FusionConfig {
        get { fusion.config }
        set { fusion.config = newValue }
    }
    public var interactionConfig: InteractionConfig {
        get { interaction.config }
        set { interaction.config = newValue }
    }

    private let analyzer: SpectrumAnalyzer
    private let slicer: FrameSlicer
    private let extractors: [FeatureExtractor]
    private let detectors: [PushDetector]
    /// Pull (away → toward) on the strongest tone.
    private var pullDetector: PushDetector!
    private let fusion = GestureFusion()
    private let trackers: [BasebandTracker]
    private let interaction = InteractionDetector()
    private var mono: [Float] = []
    /// Index of the lowest-frequency pilot (the strongest echo on this hardware).
    private var strongestBand: Int { bands.indices.min { bands[$0].pilotHz < bands[$1].pilotHz } ?? 0 }
    private var spectrum = [Float]()
    private let audible: AudibleLevel
    private var lastAcceptedEnd = -Double.infinity
    /// Until when push-shaped motions count as part of a run of swipes.
    private var swipeStreakUntil = -Double.infinity
    private var claimedUntil = -Double.infinity
    /// Each tone's recent toward/away (last 1.5 s), to find a tone's turn-around when only the other tone
    /// produced an event.
    private var history: [[(time: Double, toward: Float, away: Float)]] = []
    /// Pulls wait briefly: if a push overlaps them (its toward phase was the pull's return), the push wins.
    private var pendingPull: (event: GestureEvent, release: Double)?

    /// Seconds of audio consumed.
    public var time: Double { Double(slicer.samplesConsumed) / sampleRate }
    public var frameRate: Double { sampleRate / Double(hop) }

    public static func fftSize(for sampleRate: Double) -> Int { sampleRate > 60_000 ? 8192 : 4096 }

    public convenience init(sampleRate: Double, channels: Int, pilots: [Double], detector: DetectorConfig = DetectorConfig(),
                            displayHalfWidth: Int = 64) {
        self.init(sampleRate: sampleRate, channels: channels, layout: PilotLayout(pilots: pilots), detector: detector,
                  displayHalfWidth: displayHalfWidth)
    }

    public init(sampleRate: Double, channels: Int, layout: PilotLayout, detector: DetectorConfig = DetectorConfig(),
                fusion fusionConfig: FusionConfig = FusionConfig(), interaction interactionConfig: InteractionConfig = InteractionConfig(),
                displayHalfWidth: Int = 64) {
        self.layout = layout
        self.sampleRate = sampleRate
        self.channels = channels
        fftSize = Self.fftSize(for: sampleRate)
        hop = fftSize / 8
        self.displayHalfWidth = displayHalfWidth
        detectorConfig = detector
        analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: sampleRate)
        slicer = FrameSlicer(channels: channels, fftSize: fftSize, hop: hop)
        let binWidth = sampleRate / Double(Self.fftSize(for: sampleRate))
        let frameRate = sampleRate / Double(hop)
        audible = AudibleLevel(bins: Int(1000 / binWidth)...Int(4000 / binWidth), frameRate: frameRate)
        switch layout {
        case .single(let f):
            bands = [PilotBand(pilotHz: f, binWidth: binWidth)]
            extractors = bands.map { FeatureExtractor(band: $0, frameRate: frameRate, warmUp: detector.warmUp) }
        case .stereo(let l, let r):
            // Narrow each Doppler band so the two can't overlap, and keep the reference bands on the
            // outer sides (away from the other pilot).
            let lo = min(l, r), hi = max(l, r)
            let separation = Int(((hi - lo) / binWidth).rounded())
            let outer = max(12, min(32, separation / 2 - 2))
            let left = PilotBand(pilotHz: l, binWidth: binWidth, outerBins: outer)
            let right = PilotBand(pilotHz: r, binWidth: binWidth, outerBins: outer)
            bands = [left, right]
            extractors = [
                FeatureExtractor(band: left, frameRate: frameRate, warmUp: detector.warmUp,
                                 referenceLower: l <= r, referenceUpper: l > r),
                FeatureExtractor(band: right, frameRate: frameRate, warmUp: detector.warmUp,
                                 referenceLower: r < l, referenceUpper: r >= l),
            ]
        }
        detectors = bands.map { PushDetector(pilotHz: $0.pilotHz, config: detector) }
        let strongestHz = bands.map(\.pilotHz).min() ?? bands[0].pilotHz
        pullDetector = PushDetector(pilotHz: strongestHz, config: detector, mirrored: true)
        trackers = bands.map { BasebandTracker(pilotHz: $0.pilotHz, sampleRate: sampleRate) }
        fusion.config = fusionConfig
        history = Array(repeating: [], count: bands.count)
        interaction.config = interactionConfig
        interaction.detector = detector
        fusion.reversalFinder = { [unowned self] band, t in self.turnaround(band: band, around: t) }
    }

    /// When tone `band`'s echo last turned from toward to away within 0.3 s of `t0` (the crossing nearest to it),
    /// using looser thresholds than a full gesture: both sides above the off level and 2 dB apart.
    func turnaround(band: Int, around t0: Double, awayFirst: Bool = false) -> Double? {
        guard history.indices.contains(band) else { return nil }
        let off = detectorConfig.effectiveOffDB
        var lastToward: Double?
        var peakToward: Float = 0
        var best: Double?
        for raw in history[band] where abs(raw.time - t0) <= 0.3 {
            // For a pull the first phase is away: swap so the same search finds away → toward.
            let f = awayFirst ? (time: raw.time, toward: raw.away, away: raw.toward) : raw
            if f.toward >= off && f.toward - f.away >= 2 {
                lastToward = f.time
                peakToward = max(peakToward, f.toward)
            } else if let lt = lastToward, f.away >= off && f.away - f.toward >= 2 {
                if f.time - lt <= 0.12 && peakToward >= off + 2 && (best.map { abs(f.time - t0) < abs($0 - t0) } ?? true) {
                    best = f.time
                }
                lastToward = nil
                peakToward = 0
            }
        }
        return best
    }

    /// Whether the other tone turned from away to toward within a frame of the pull's own turn (both measured
    /// the same way).
    private func pullSeenByBothTones(_ pull: GestureEvent) -> Bool {
        guard let rev = pull.reversal else { return false }
        let mine = turnaround(band: strongestBand, around: rev, awayFirst: true) ?? rev
        return bands.indices.filter { $0 != strongestBand }.allSatisfy { other in
            guard let theirs = turnaround(band: other, around: mine, awayFirst: true) else { return false }
            return abs(theirs - mine) <= fusion.config.pushMaxLag
        }
    }

    /// Keyboard/trackpad input happened at stream time `t`. Feed in time order.
    public func noteInput(at t: Double) {
        detectors.forEach { $0.noteInput(at: t) }
        pullDetector.noteInput(at: t)
        interaction.noteInput(at: t)
    }

    /// Forget the still-hand baseline (after the pilot level or frequency changes).
    public func resetBaselines() {
        extractors.forEach { $0.reset() }
        detectors.forEach { $0.reset() }
        pullDetector.reset()
        pendingPull = nil
        claimedUntil = -Double.infinity
        fusion.reset()
        history = Array(repeating: [], count: bands.count)
        trackers.forEach { $0.reset() }
        interaction.reset()
        audible.reset()
    }

    public func process(_ samples: [[Float]]) -> PipelineOutput {
        var out = PipelineOutput()
        for ch in samples {
            for s in ch { out.peak = max(out.peak, abs(s)) }
        }
        // Phase trackers run on the mono mix of the mic channels, ahead of the FFT frames that read them.
        if let n = samples.first?.count, n > 0 {
            if samples.count == 1 {
                samples[0].withUnsafeBufferPointer { buf in trackers.forEach { $0.process(buf) } }
            } else {
                if mono.count != n { mono = [Float](repeating: 0, count: n) }
                for i in 0..<n { mono[i] = samples.reduce(0) { $0 + $1[i] } / Float(samples.count) }
                mono.withUnsafeBufferPointer { buf in trackers.forEach { $0.process(buf) } }
            }
        }
        let frameSeconds = Double(hop) / sampleRate
        slicer.push(samples) { windows in
            analyzer.averagePowerSpectrum(windows, into: &spectrum)
            let t = Double(slicer.samplesConsumed) / sampleRate
            let audibleDB = audible.process(spectrum)
            var features: [BandFeatures] = []
            features.reserveCapacity(bands.count)
            spectrum.withUnsafeBufferPointer { spec in
                for (i, extractor) in extractors.enumerated() {
                    var f = extractor.process(spec, time: t)
                    let bb = trackers[i].frame(endingAt: slicer.samplesConsumed, frameSeconds: frameSeconds)
                    f.microDB = bb.microDB
                    f.displacement = bb.displacement
                    f.basebandVelocity = bb.velocity
                    f.audibleDB = audibleDB
                    features.append(f)
                    history[i].append((t, f.towardDB, f.awayDB))
                    if let first = history[i].first, t - first.time > 1.5 { history[i].removeFirst() }
                    guard let event = detectors[i].process(f) else { continue }
                    if layout.isStereo {
                        fusion.add(event, band: i).forEach { accept($0, into: &out) }
                    } else {
                        accept(event, into: &out)
                    }
                }
            }
            if layout.isStereo { fusion.flush(now: t).forEach { accept($0, into: &out) } }
            // Hover and grab follow the strongest (lowest-frequency) tone only: averaging in a weaker tone
            // just adds noise. Pulls come from the same tone.
            let strongest = features[strongestBand]
            if var pull = pullDetector.process(strongest), interaction.config.pullEnabled || interaction.isEngaged {
                if pull.isAccepted && layout.isStereo && !pullSeenByBothTones(pull) {
                    // A pull comes straight at the laptop, so both tones turn around together; a swipe's
                    // back-and-forth on one tone doesn't.
                    pull.outcome = .unclear
                }
                if pull.isAccepted {
                    pendingPull = (pull, t + detectorConfig.maxReversalGap + detectorConfig.endHold + 0.05)
                } else {
                    accept(pull, into: &out)
                }
            }
            if let pending = pendingPull, t >= pending.release {
                pendingPull = nil
                accept(pending.event, into: &out)
            }
            let (controls, interactionEvents) = interaction.process(strongest, pilotHz: bands[strongestBand].pilotHz)
            out.controls += controls
            interactionEvents.forEach { accept($0, into: &out) }
            out.frames.append(PipelineFrame(time: t, bands: features, display: wantsDisplay ? displayColumn() : []))
        }
        out.interactionPhase = interaction.phase
        return out
    }

    /// One view of all pilots for the interaction detector: strongest sideband energy, mean displacement.
    static func combine(_ features: [BandFeatures]) -> BandFeatures {
        guard var c = features.first, features.count > 1 else { return features.first! }
        let n = Float(features.count)
        let strongest = features.max { max($0.towardDB, $0.awayDB) < max($1.towardDB, $1.awayDB) }!
        c.towardDB = features.map(\.towardDB).max()!
        c.awayDB = features.map(\.awayDB).max()!
        c.referenceDB = features.map(\.referenceDB).max()!
        c.velocity = strongest.velocity
        c.microDB = features.map(\.microDB).max()!
        c.displacement = features.map(\.displacement).reduce(0, +) / n
        c.basebandVelocity = features.map(\.basebandVelocity).reduce(0, +) / n
        c.quiet = features.allSatisfy(\.quiet)
        return c
    }

    /// One motion, one gesture. A push's second half looks like the start of a pull (and push-push like
    /// push-pull-push), so once a gesture is accepted, candidates that *started inside it* are dropped.
    /// A pull and a push can share a stroke (the pull's return is the push's toward phase); `pullBeatsPush`
    /// decides which one the hand meant. While hovering, gestures turn into controls instead.
    private func accept(_ event: GestureEvent, into out: inout PipelineOutput) {
        if event.start < claimedUntil - 0.02 { return }
        if event.kind == .swipeLeft || event.kind == .swipeRight, event.isAccepted, let pending = pendingPull,
           event.start <= pending.event.end + 0.05 {
            pendingPull = nil  // the swipe's own toward/away looked like a pull on one tone
        }
        if event.kind == .push, event.isAccepted, let pending = pendingPull, event.start <= pending.event.end + 0.05 {
            pendingPull = nil
            if Self.pullBeatsPush(pending.event, event) {
                deliver(pending.event, into: &out)
                claimedUntil = max(claimedUntil, event.end)
                return
            }
            // Otherwise the "pull" was just the little dip before this push.
        }
        deliver(event, into: &out)
    }

    /// Pull (away, then back) vs a push whose toward phase is that same return stroke. The pull wins when it
    /// clearly came first and its away stroke was at least about as big or as fast as the push's away
    /// stroke — that one is only the hand settling after the pull. Measured on real pulls vs pushes with a
    /// lead-in dip, this separates all of them.
    static func pullBeatsPush(_ pull: GestureEvent, _ push: GestureEvent) -> Bool {
        guard pull.start < push.start - 0.05 else { return false }
        let firstStroke = pull.awayPeakDB, firstSpeed = abs(pull.awayPeakVelocity)
        return firstStroke >= push.awayPeakDB - 4 || firstSpeed >= abs(push.awayPeakVelocity) + 0.2
    }

    private func deliver(_ event: GestureEvent, into out: inout PipelineOutput) {
        var event = event
        if layout.isStereo {
            if event.isAccepted && (event.kind == .swipeLeft || event.kind == .swipeRight) {
                swipeStreakUntil = event.end + fusion.config.swipeStreak
            } else if event.kind == .push || event.kind == .pull, event.end < swipeStreakUntil,
                      event.isAccepted || (event.outcome == .oneSided && max(event.towardPeakDB, event.awayPeakDB) >= 12) {
                // In a run of swipes, a push-shaped motion without a clear left/right timing is a swipe that passed
                // the middle (or one only one tone caught). It isn't a push, and it keeps the run going.
                if event.isAccepted { event.outcome = .duringSwipes }
                swipeStreakUntil = event.end + fusion.config.swipeStreak
            }
        }
        if event.isAccepted {
            // Several pilots may see the same push: keep the first.
            guard event.end - lastAcceptedEnd > 0.3 else { return }
        }
        if let consumed = interaction.consume(event) {
            out.controls += consumed.controls
            if consumed.swallow {
                if event.isAccepted { claimedUntil = event.end; lastAcceptedEnd = event.end }
                return
            }
        }
        if event.isAccepted {
            claimedUntil = event.end
            lastAcceptedEnd = event.end
            interaction.noteGesture(at: event.end)
        }
        out.events.append(event)
    }

    private func displayColumn() -> [Float] {
        var column: [Float] = []
        column.reserveCapacity(bands.count * (2 * displayHalfWidth + 1))
        for band in bands {
            for k in (band.pilotBin - displayHalfWidth)...(band.pilotBin + displayHalfWidth) {
                column.append(k >= 0 && k < spectrum.count ? spectrum[k].dB : -200)
            }
        }
        return column
    }
}

/// Level of the audible band (1–4 kHz) over its own running level, in dB. Follows the room (speech, music)
/// over about a second; short bursts barely move it.
final class AudibleLevel {
    let bins: ClosedRange<Int>
    private let alpha: Float
    private var baseline: Float?

    init(bins: ClosedRange<Int>, frameRate: Double) {
        self.bins = bins
        alpha = Float(1 / (1.0 * frameRate))
    }

    func reset() { baseline = nil }

    func process(_ spectrum: [Float]) -> Float {
        guard bins.upperBound < spectrum.count else { return 0 }
        var sum: Float = 0
        for k in bins { sum += spectrum[k] }
        let level = 10 * log10(sum / Float(bins.count) + 1e-20)
        guard let b = baseline else { baseline = level; return 0 }
        let over = level - b
        // Bursts (more than 6 dB up) are let in 20× more slowly, so a knock doesn't raise its own baseline.
        baseline = b + over * (over > 6 ? alpha / 20 : alpha)
        return over
    }
}
