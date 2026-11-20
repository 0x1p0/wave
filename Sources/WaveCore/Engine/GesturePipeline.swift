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
        didSet { detectors.forEach { $0.config = detectorConfig } }
    }
    public var fusionConfig: FusionConfig {
        get { fusion.config }
        set { fusion.config = newValue }
    }

    private let analyzer: SpectrumAnalyzer
    private let slicer: FrameSlicer
    private let extractors: [FeatureExtractor]
    private let detectors: [PushDetector]
    private let fusion = GestureFusion()
    private var spectrum = [Float]()
    private var lastAcceptedEnd = -Double.infinity

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
                fusion fusionConfig: FusionConfig = FusionConfig(), displayHalfWidth: Int = 64) {
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
        fusion.config = fusionConfig
    }

    /// Keyboard/trackpad input happened at stream time `t`. Feed in time order.
    public func noteInput(at t: Double) { detectors.forEach { $0.noteInput(at: t) } }

    /// Forget the still-hand baseline (after the pilot level or frequency changes).
    public func resetBaselines() {
        extractors.forEach { $0.reset() }
        detectors.forEach { $0.reset() }
        fusion.reset()
    }

    public func process(_ samples: [[Float]]) -> PipelineOutput {
        var out = PipelineOutput()
        for ch in samples {
            for s in ch { out.peak = max(out.peak, abs(s)) }
        }
        slicer.push(samples) { windows in
            analyzer.averagePowerSpectrum(windows, into: &spectrum)
            let t = Double(slicer.samplesConsumed) / sampleRate
            var features: [BandFeatures] = []
            features.reserveCapacity(bands.count)
            spectrum.withUnsafeBufferPointer { spec in
                for (i, extractor) in extractors.enumerated() {
                    let f = extractor.process(spec, time: t)
                    features.append(f)
                    guard let event = detectors[i].process(f) else { continue }
                    if layout.isStereo {
                        fusion.add(event, band: i).forEach { accept($0, into: &out) }
                    } else {
                        accept(event, into: &out)
                    }
                }
            }
            if layout.isStereo { fusion.flush(now: t).forEach { accept($0, into: &out) } }
            out.frames.append(PipelineFrame(time: t, bands: features, display: wantsDisplay ? displayColumn() : []))
        }
        return out
    }

    private func accept(_ event: GestureEvent, into out: inout PipelineOutput) {
        if event.isAccepted {
            // Several pilots may see the same push: keep the first.
            guard event.end - lastAcceptedEnd > 0.3 else { return }
            lastAcceptedEnd = event.end
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
