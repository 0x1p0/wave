import AVFoundation
import Foundation

/// Sidecar JSON saved next to each debug recording (`name.caf` + `name.json`).
public struct RecordingMetadata: Codable, Sendable {
    public var version = 1
    public var created = Date()
    public var sampleRate: Double
    public var channels: Int
    public var pilots: [Double]
    public var amplitudeDBFS: Double?
    public var speakerGainDB: Double?
    public var micDevice: String
    public var machine: String
    /// Keyboard/trackpad input times, seconds from the start of the recording.
    public var inputTimes: [Double] = []
    /// What the live detector reported while recording (times relative to the recording).
    public var liveEvents: [GestureEvent] = []
    public var detector: DetectorConfig?
    /// Optional label (e.g. "push", "none") for building datasets later.
    public var label: String?
    public var duration: Double = 0

    private enum CodingKeys: String, CodingKey {
        case version, created, sampleRate, channels, pilots, amplitudeDBFS, speakerGainDB, micDevice, machine
        case inputTimes, liveEvents, detector, label, duration
    }

    /// Tolerant decoding: only the audio format is required; everything else falls back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        channels = try c.decode(Int.self, forKey: .channels)
        pilots = (try? c.decodeIfPresent([Double].self, forKey: .pilots)) ?? [19_000]
        micDevice = (try? c.decodeIfPresent(String.self, forKey: .micDevice)) ?? "?"
        machine = (try? c.decodeIfPresent(String.self, forKey: .machine)) ?? "?"
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        created = (try? c.decodeIfPresent(Date.self, forKey: .created)) ?? Date(timeIntervalSince1970: 0)
        amplitudeDBFS = try? c.decodeIfPresent(Double.self, forKey: .amplitudeDBFS)
        speakerGainDB = try? c.decodeIfPresent(Double.self, forKey: .speakerGainDB)
        inputTimes = (try? c.decodeIfPresent([Double].self, forKey: .inputTimes)) ?? []
        liveEvents = (try? c.decodeIfPresent([GestureEvent].self, forKey: .liveEvents)) ?? []
        detector = try? c.decodeIfPresent(DetectorConfig.self, forKey: .detector)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0
    }

    public init(sampleRate: Double, channels: Int, pilots: [Double], micDevice: String, machine: String) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.pilots = pilots
        self.micDevice = micDevice
        self.machine = machine
    }
}

/// Writes raw mic audio (float32 CAF) plus a JSON sidecar. Debug-only and opt-in: nothing else in Wave
/// ever writes audio to disk.
public final class RecordingWriter {
    public let url: URL
    public private(set) var metadata: RecordingMetadata
    /// Stream time at which the recording started; all stored times are relative to it.
    public let streamStart: Double

    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var frames = 0

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wave/Recordings", isDirectory: true)
    }

    /// New recording in `directory`, named wave-YYYYMMDD-HHMMSS[-label].caf.
    public convenience init(directory: URL, metadata: RecordingMetadata, streamStart: Double) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        var name = "wave-\(stamp.string(from: metadata.created))"
        if let label = metadata.label, !label.isEmpty { name += "-\(label)" }
        try self.init(url: directory.appendingPathComponent(name).appendingPathExtension("caf"),
                      metadata: metadata, streamStart: streamStart)
    }

    public init(url fileURL: URL, metadata: RecordingMetadata, streamStart: Double) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: metadata.sampleRate,
            channels: AVAudioChannelCount(metadata.channels), interleaved: false)
        else { throw CoreAudioError(-1, "AVAudioFormat") }
        // autoreleasepool: AVAudioFile only closes (and flushes its last block) when it is really released.
        let audioFile = try autoreleasepool {
            try AVAudioFile(forWriting: fileURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        url = fileURL
        self.format = format
        file = audioFile
        self.metadata = metadata
        self.streamStart = streamStart
    }

    public func append(_ samples: [[Float]]) throws {
        guard let file, let n = samples.first?.count, n > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
        buffer.frameLength = AVAudioFrameCount(n)
        for (ch, data) in samples.enumerated() where ch < metadata.channels {
            data.withUnsafeBufferPointer { buffer.floatChannelData![ch].update(from: $0.baseAddress!, count: n) }
        }
        try autoreleasepool { try file.write(from: buffer) }
        frames += n
    }

    public func noteInput(at streamTime: Double) {
        let t = streamTime - streamStart
        if t >= -1 { metadata.inputTimes.append(t) }
    }

    public func noteEvent(_ event: GestureEvent) {
        var e = event
        e.start -= streamStart
        e.end -= streamStart
        metadata.liveEvents.append(e)
    }

    /// Closes the audio file and writes the sidecar. Returns the .caf URL.
    @discardableResult
    public func finish() throws -> URL {
        if #available(macOS 15.0, *) { file?.close() }
        file = nil  // on macOS 14 AVAudioFile flushes and closes when released
        metadata.duration = Double(frames) / metadata.sampleRate
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: Self.sidecarURL(for: url))
        return url
    }

    public static func sidecarURL(for caf: URL) -> URL { caf.deletingPathExtension().appendingPathExtension("json") }
}

/// A recording loaded into memory.
public struct LoadedRecording: Sendable {
    public var url: URL
    public var metadata: RecordingMetadata?
    public var sampleRate: Double
    public var channels: [[Float]]

    public var frameCount: Int { channels.first?.count ?? 0 }
    public var duration: Double { Double(frameCount) / sampleRate }

    public static func load(_ url: URL) throws -> LoadedRecording {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw CoreAudioError(-1, "AVAudioPCMBuffer")
        }
        var channels = [[Float]](repeating: [], count: Int(format.channelCount))
        for ch in channels.indices { channels[ch].reserveCapacity(Int(file.length)) }
        // read(into:) may return fewer frames than requested, so loop to the end.
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            for ch in channels.indices {
                channels[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: n))
            }
        }
        var metadata: RecordingMetadata?
        let sidecar = RecordingWriter.sidecarURL(for: url)
        if let data = try? Data(contentsOf: sidecar) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            metadata = try decoder.decode(RecordingMetadata.self, from: data)
        }
        return LoadedRecording(url: url, metadata: metadata, sampleRate: format.sampleRate, channels: channels)
    }
}

/// Runs a recording through the pipeline as fast as possible — the repeatable tuning loop.
public enum Replay {
    public struct Result: Sendable {
        public var recording: LoadedRecording
        public var pilots: [Double]
        public var events: [GestureEvent]
        public var frames: Int
    }

    /// - Parameters:
    ///   - pilots: override the pilots stored in the sidecar.
    ///   - onOutput: sees every chunk's output (features, display columns if `wantsDisplay`).
    public static func run(
        _ recording: LoadedRecording, pilots: [Double]? = nil, detector: DetectorConfig = DetectorConfig(),
        fusion: FusionConfig = FusionConfig(), interaction: InteractionConfig = InteractionConfig(), wantsDisplay: Bool = false,
        chunk: Int = 480, onOutput: ((PipelineOutput) -> Void)? = nil
    ) -> Result {
        let pilots = pilots ?? recording.metadata?.pilots ?? [19_000]
        let pipeline = GesturePipeline(
            sampleRate: recording.sampleRate, channels: recording.channels.count, layout: PilotLayout(pilots: pilots),
            detector: detector, fusion: fusion, interaction: interaction)
        pipeline.wantsDisplay = wantsDisplay
        let inputs = (recording.metadata?.inputTimes ?? []).sorted()
        var nextInput = 0
        var events: [GestureEvent] = []
        var frames = 0
        var offset = 0
        let n = recording.frameCount
        while offset < n {
            let end = min(n, offset + chunk)
            let tEnd = Double(end) / recording.sampleRate
            while nextInput < inputs.count && inputs[nextInput] <= tEnd {
                pipeline.noteInput(at: inputs[nextInput])
                nextInput += 1
            }
            let out = pipeline.process(recording.channels.map { Array($0[offset..<end]) })
            events += out.events
            frames += out.frames.count
            onOutput?(out)
            offset = end
        }
        return Result(recording: recording, pilots: pilots, events: events, frames: frames)
    }
}
