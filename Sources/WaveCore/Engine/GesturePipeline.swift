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
    public let displayHalfWidth: Int
    public var wantsDisplay = false
    public var detectorConfig: DetectorConfig {
        didSet { detectors.forEach { $0.config = detectorConfig } }
    }

    private let analyzer: SpectrumAnalyzer
    private let slicer: FrameSlicer
    private let extractors: [FeatureExtractor]
    private let detectors: [PushDetector]
    private var spectrum = [Float]()
    private var lastAcceptedEnd = -Double.infinity

    /// Seconds of audio consumed.
    public var time: Double { Double(slicer.samplesConsumed) / sampleRate }
    public var frameRate: Double { sampleRate / Double(hop) }

    public static func fftSize(for sampleRate: Double) -> Int { sampleRate > 60_000 ? 8192 : 4096 }

    public init(sampleRate: Double, channels: Int, pilots: [Double], detector: DetectorConfig = DetectorConfig(),
                displayHalfWidth: Int = 64) {
        precondition(!pilots.isEmpty)
        self.sampleRate = sampleRate
        self.channels = channels
        fftSize = Self.fftSize(for: sampleRate)
        hop = fftSize / 8
        self.displayHalfWidth = displayHalfWidth
        detectorConfig = detector
        analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: sampleRate)
        slicer = FrameSlicer(channels: channels, fftSize: fftSize, hop: hop)
        bands = pilots.map { PilotBand(pilotHz: $0, binWidth: sampleRate / Double(Self.fftSize(for: sampleRate))) }
        let frameRate = sampleRate / Double(hop)
        extractors = bands.map { FeatureExtractor(band: $0, frameRate: frameRate, warmUp: detector.warmUp) }
        detectors = bands.map { PushDetector(pilotHz: $0.pilotHz, config: detector) }
    }

    /// Keyboard/trackpad input happened at stream time `t`. Feed in time order.
    public func noteInput(at t: Double) { detectors.forEach { $0.noteInput(at: t) } }

    /// Forget the still-hand baseline (after the pilot level or frequency changes).
    public func resetBaselines() {
        extractors.forEach { $0.reset() }
        detectors.forEach { $0.reset() }
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
                    if let event = detectors[i].process(f) { accept(event, into: &out) }
                }
            }
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
