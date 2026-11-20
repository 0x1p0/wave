import AppKit
import Foundation
import Observation
import WaveCore

/// State behind the debug window. Owns a SonarEngine and turns its output into view state.
@MainActor
@Observable
public final class DebugModel {
    // MARK: Controls
    public var pilotHz: Double = 19_000 { didSet { if oldValue != pilotHz { pushSettings() } } }
    public var amplitudeDBFS: Double = -8 { didSet { if oldValue != amplitudeDBFS { pushSettings() } } }
    public var sensitivity: Double = 0.5 { didSet { if oldValue != sensitivity { pushSettings() } } }
    public var showRejected = true
    public var recordLabel = ""

    // MARK: Engine state
    public private(set) var status: EngineStatus = .stopped
    public private(set) var currentAmplitude: Double?
    public private(set) var speakerGainDB: Double?
    public private(set) var inputIdle: Double?
    public private(set) var droppedFrames: Int64 = 0
    public private(set) var recordingURL: URL?
    public private(set) var lastSavedRecording: URL?
    public private(set) var replayingFile: String?
    /// Newest first.
    public private(set) var events: [GestureEvent] = []
    public private(set) var latest: BandFeatures?
    /// Bumped whenever `history` changes (drives redraws).
    public private(set) var revision = 0

    /// Called for every new gesture event (the menu bar app uses this to act on gestures while the debug
    /// window has taken over listening).
    @ObservationIgnored public var onEvent: ((GestureEvent) -> Void)?
    /// Hold / dial events (the app uses them for volume/brightness while the debug window listens).
    @ObservationIgnored public var onControl: ((ControlEvent) -> Void)?
    /// Engine settings supplied by a host app (pilot layout, calibrated detector). The level and
    /// sensitivity controls still apply on top.
    @ObservationIgnored public var baseSettings: EngineSettings?

    @ObservationIgnored public let history = FeatureHistory()
    @ObservationIgnored private var engine: SonarEngine?
    @ObservationIgnored private var lastIdleShown = 0.0
    @ObservationIgnored private var lastRedraw = 0.0
    @ObservationIgnored private var lastLatest = 0.0
    /// Plot refresh rate; the engine delivers ~30 batches/s and frames accumulate in `history` regardless.
    @ObservationIgnored public var maxRedrawRate = 20.0

    public var detectorConfig: DetectorConfig {
        var c = baseSettings?.detector ?? DetectorConfig()
        c.sensitivity = sensitivity
        return c
    }

    public var settings: EngineSettings {
        var s = baseSettings ?? EngineSettings()
        if baseSettings == nil { s.pilots = [pilotHz] }
        s.level.referenceAmplitudeDBFS = amplitudeDBFS
        s.detector = detectorConfig
        return s
    }

    public var acceptedCount: Int { events.filter(\.isAccepted).count }

    public init() {
        engine = SonarEngine { [weak self] output in
            let model = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model?.ingest(output) }
            }
        }
        engine?.setDisplayEnabled(true)
    }

    // MARK: Actions

    public func start() {
        replayingFile = nil
        history.clear()
        engine?.start(settings)
    }

    public func stop() { engine?.stop() }

    public func shutdown() { engine?.stopAndWait() }

    public func toggleRecording() {
        if recordingURL != nil {
            engine?.stopRecording()
        } else {
            let label = recordLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            engine?.startRecording(label: label.isEmpty ? nil : label)
        }
    }

    /// Real-time replay of a recording through the engine (same views as live).
    public func replay(_ url: URL, speed: Double = 1) {
        history.clear()
        events.removeAll()
        replayingFile = url.lastPathComponent
        engine?.startReplay(url, settings: settings, speed: speed)
    }

    /// Instant replay (no pacing), e.g. for snapshots. Fills the views with the end of the file.
    public func replayImmediately(_ recording: LoadedRecording) {
        engine?.stop()
        history.clear()
        events.removeAll()
        replayingFile = recording.url.lastPathComponent
        let result = Replay.run(recording, detector: detectorConfig, wantsDisplay: true) { out in
            for frame in out.frames { self.history.append(frame, halfWidth: 64, bandCount: 1) }
            if let f = out.frames.last?.bands.first { self.latest = f }
        }
        events = result.events.reversed()
        status = .stopped
        revision += 1
    }

    public func clearEvents() { events.removeAll() }

    public func revealRecordings() {
        let url = lastSavedRecording ?? RecordingWriter.defaultDirectory
        if lastSavedRecording != nil {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Engine output

    private func pushSettings() {
        guard status.isActive else { return }
        if case .replaying = status { return }
        engine?.update(settings)
    }

    func ingest(_ out: EngineOutput) {
        if out.status != status { status = out.status }
        if out.amplitudeDBFS != currentAmplitude { currentAmplitude = out.amplitudeDBFS }
        if out.speakerGainDB != speakerGainDB { speakerGainDB = out.speakerGainDB }
        if out.droppedFrames != droppedFrames { droppedFrames = out.droppedFrames }
        if out.recordingURL != recordingURL { recordingURL = out.recordingURL }
        if let saved = out.savedRecording { lastSavedRecording = saved }
        if let idle = out.inputIdle, abs(idle - lastIdleShown) > 0.2 || idle < lastIdleShown {
            lastIdleShown = idle
            inputIdle = idle
        }
        out.controls.forEach { onControl?($0) }
        if !out.events.isEmpty {
            out.events.forEach { onEvent?($0) }
            events.insert(contentsOf: out.events.reversed(), at: 0)
            if events.count > 500 { events.removeLast(events.count - 500) }
        }
        if !out.frames.isEmpty {
            for frame in out.frames { history.append(frame, halfWidth: out.displayHalfWidth, bandCount: max(1, out.bands.count)) }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastLatest >= 0.2 {
                lastLatest = now
                latest = out.frames.last?.bands.first
            }
            if now - lastRedraw >= 1 / maxRedrawRate || !out.events.isEmpty {
                lastRedraw = now
                revision += 1
            }
        }
    }
}
