import Foundation

/// A labeled window of per-frame features (no audio), for training a classifier later.
public struct LabeledSample: Codable, Sendable {
    public var label: String
    public var pilots: [Double]
    public var frameRate: Double
    /// Stream time of the last frame.
    public var endTime: Double
    /// frames × features; see `featureNames(bands:)` for the column order.
    public var features: [[Float]]

    public static let perBand = ["toward_db", "away_db", "reference_db", "velocity", "pilot_db", "reflection_db",
                                 "micro_db", "displacement_mm", "phase_velocity"]

    public static func featureNames(bands: Int) -> [String] {
        (0..<bands).flatMap { b in perBand.map { "b\(b)_\($0)" } }
    }

    static func row(_ frame: PipelineFrame) -> [Float] {
        frame.bands.flatMap { [$0.towardDB, $0.awayDB, $0.referenceDB, $0.velocity, $0.pilotDB, $0.reflectionDB,
                               $0.microDB, $0.displacement * 1000, $0.basebandVelocity] }
    }
}

/// Keeps the last few seconds of frames so a fixed-length window can be cut around any moment.
public final class FeatureWindowRecorder {
    public let windowFrames: Int
    public let frameRate: Double
    private var frames: [PipelineFrame] = []

    public init(windowSeconds: Double = 1.2, frameRate: Double = 48_000.0 / 512) {
        self.frameRate = frameRate
        windowFrames = max(8, Int(windowSeconds * frameRate))
    }

    public func append(_ new: [PipelineFrame]) {
        frames += new
        let keep = windowFrames * 3
        if frames.count > keep { frames.removeFirst(frames.count - keep) }
    }

    public var latestTime: Double? { frames.last?.time }

    /// The `windowFrames` frames ending at (or just before) `time`, or nil if there aren't enough yet.
    public func window(endingAt time: Double, label: String, pilots: [Double]) -> LabeledSample? {
        guard let endIndex = frames.lastIndex(where: { $0.time <= time + 1e-9 }), endIndex + 1 >= windowFrames else { return nil }
        let slice = frames[(endIndex + 1 - windowFrames)...endIndex]
        return LabeledSample(label: label, pilots: pilots, frameRate: frameRate, endTime: frames[endIndex].time,
                             features: slice.map(LabeledSample.row))
    }
}

/// Writes labeled samples as JSON (one document) and CSV (one row per frame).
public enum SampleExport {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wave/Samples", isDirectory: true)
    }

    @discardableResult
    public static func write(_ samples: [LabeledSample], to directory: URL = defaultDirectory, name: String? = nil) throws -> (json: URL, csv: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let base = name ?? "wave-samples-\(stamp.string(from: Date()))"
        let json = directory.appendingPathComponent(base).appendingPathExtension("json")
        let csv = directory.appendingPathComponent(base).appendingPathExtension("csv")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bands = samples.first?.pilots.count ?? 1
        struct Document: Encodable {
            let version = 1
            let featureNames: [String]
            let samples: [LabeledSample]
        }
        try encoder.encode(Document(featureNames: LabeledSample.featureNames(bands: bands), samples: samples)).write(to: json)

        var text = (["sample", "label", "frame", "time"] + LabeledSample.featureNames(bands: bands)).joined(separator: ",") + "\n"
        for (i, s) in samples.enumerated() {
            let t0 = s.endTime - Double(s.features.count - 1) / s.frameRate
            for (j, row) in s.features.enumerated() {
                text += "\(i),\(s.label),\(j),\(String(format: "%.4f", t0 + Double(j) / s.frameRate)),"
                text += row.map { String(format: "%.3f", $0) }.joined(separator: ",") + "\n"
            }
        }
        try text.write(to: csv, atomically: true, encoding: .utf8)
        return (json, csv)
    }
}
