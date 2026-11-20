import AudioToolbox
import Foundation

public struct EngineSettings: Sendable, Equatable {
    /// One tone on both speakers (push), or one per speaker (push + swipes).
    public var layout = PilotLayout.single(19_000)
    public var level = PilotLevelPolicy()
    public var detector = DetectorConfig()
    public var fusion = FusionConfig()
    public var interaction = InteractionConfig()
    public init() {}

    /// Convenience for single-pilot callers.
    public var pilots: [Double] {
        get { layout.frequencies }
        set { layout = PilotLayout(pilots: newValue) }
    }
}

public enum EngineStatus: Sendable, Equatable {
    case stopped
    case running
    case replaying(progress: Double)
    case paused(String)
    case failed(String)

    public var text: String {
        switch self {
        case .stopped: return "Stopped"
        case .running: return "Listening"
        case .replaying(let p): return "Replaying (\(Int(p * 100)) %)"
        case .paused(let reason): return "Paused: \(reason)"
        case .failed(let reason): return reason
        }
    }

    public var isActive: Bool {
        switch self {
        case .running, .replaying, .paused: return true
        case .stopped, .failed: return false
        }
    }
}

/// A batch of engine results, delivered ~30 times a second on the engine queue.
public struct EngineOutput: Sendable {
    public var frames: [PipelineFrame] = []
    public var events: [GestureEvent] = []
    /// Hover interaction events, in order.
    public var controls: [ControlEvent] = []
    /// Hover state right now.
    public var interactionPhase: InteractionDetector.Phase = .idle
    public var status: EngineStatus = .stopped
    public var bands: [PilotBand] = []
    public var displayHalfWidth = 64
    /// Digital pilot level now playing (nil when the pilot is off).
    public var amplitudeDBFS: Double?
    public var speakerGainDB: Double?
    public var speakerMuted = false
    public var inputIdle: Double?
    public var droppedFrames: Int64 = 0
    /// The recording in progress, if any.
    public var recordingURL: URL?
    /// Set once, when a recording has been saved.
    public var savedRecording: URL?
}

/// Live sonar: built-in speakers play the pilot, the built-in mic feeds the gesture pipeline.
/// All state lives on one serial queue; the public methods are thread-safe.
public final class SonarEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wave.sonar-engine", qos: .userInteractive)
    private let onOutput: @Sendable (EngineOutput) -> Void

    // MARK: Queue-confined state
    private var settings = EngineSettings()
    private var status: EngineStatus = .stopped
    private var speakers: AudioDevice?
    private var pilot: PilotPlayer?
    private var capture: MicCapture?
    private var pipeline: GesturePipeline?
    private var timer: DispatchSourceTimer?
    private var idleMonitor: InputIdleMonitor?
    private var decision = PilotLevelPolicy.Decision.muted
    private var speakerGainDB: Double?
    private var speakerMuted = false
    private var inputIdle: Double?
    private var lastNotedInput = -Double.infinity
    private var silentSince: Double?
    private var micSilent = false
    private var recorder: RecordingWriter?
    private var wantsDisplay = false
    private var deliverAllFrames = true
    private var pendingFrames: [PipelineFrame] = []
    private var pendingEvents: [GestureEvent] = []
    private var pendingControls: [ControlEvent] = []
    private var interactionPhase: InteractionDetector.Phase = .idle
    private var savedRecording: URL?
    private var lastDelivery = 0.0
    private var lastVolumeCheck = 0.0
    private var lastIdleCheck = 0.0

    private struct ReplayState {
        var recording: LoadedRecording
        var offset = 0
        var speed: Double
        var startedAt: Double
        var inputs: [Double]
        var nextInput = 0
    }
    private var replay: ReplayState?

    /// - Parameter onOutput: called on the engine's queue; hop to the main actor for UI.
    public init(onOutput: @escaping @Sendable (EngineOutput) -> Void) {
        self.onOutput = onOutput
    }

    // MARK: Public API

    public func start(_ settings: EngineSettings) { queue.async { self.startLive(settings) } }

    /// Plays a recording through the pipeline in real time (× speed) instead of using the mic.
    public func startReplay(_ url: URL, settings: EngineSettings, speed: Double = 1) {
        queue.async { self.beginReplay(url, settings: settings, speed: speed) }
    }

    public func stop() { queue.async { self.stopInternal() } }

    /// Synchronous stop (pilot fades out before this returns). Use when quitting.
    public func stopAndWait() { queue.sync { self.stopInternal() } }

    /// Applies new settings without restarting where possible.
    public func update(_ settings: EngineSettings) { queue.async { self.apply(settings) } }

    /// Spectrum columns for a spectrogram cost a little extra; only compute them while someone looks.
    public func setDisplayEnabled(_ enabled: Bool) {
        queue.async {
            self.wantsDisplay = enabled
            self.pipeline?.wantsDisplay = enabled
        }
    }

    /// When false, each output carries only the newest frame (enough for status meters). Saves work when
    /// no plot is visible.
    public func setFrameDelivery(all: Bool) {
        queue.async { self.deliverAllFrames = all }
    }

    public func startRecording(directory: URL = RecordingWriter.defaultDirectory, label: String? = nil) {
        queue.async { self.beginRecording(directory: directory, label: label) }
    }

    public func stopRecording() { queue.async { self.endRecording() } }

    // MARK: Lifecycle

    private func startLive(_ s: EngineSettings) {
        stopInternal()
        settings = s
        guard MicCapture.permission == .authorized else {
            fail("Microphone access is needed (System Settings → Privacy & Security → Microphone).")
            return
        }
        guard let spk = AudioDevices.builtInSpeakers(), let mic = AudioDevices.builtInMicrophone() else {
            fail("Built-in speakers or microphone not found.")
            return
        }
        do {
            let capture = try MicCapture(device: mic)
            let pilot = try PilotPlayer(device: spk)
            let pipeline = GesturePipeline(
                sampleRate: capture.sampleRate, channels: capture.channels, layout: s.layout, detector: s.detector,
                fusion: s.fusion, interaction: s.interaction)
            pipeline.wantsDisplay = wantsDisplay
            speakers = spk
            readSpeakerLevel()
            decision = s.level.decide(speakerGainDB: speakerGainDB, muted: speakerMuted)
            try capture.start()
            let tones = decision.amplitudeDBFS == nil ? [] : Self.tones(for: pipeline)
            try pilot.start(tones: tones, amplitude: Self.linear(decision.amplitudeDBFS ?? -120))
            self.capture = capture
            self.pilot = pilot
            self.pipeline = pipeline
            idleMonitor = InputIdleMonitor()
            status = decision.pauseReason.map { .paused($0) } ?? .running
            startTimer()
            deliver()
        } catch {
            stopInternal()
            fail("Could not start audio: \(error)")
        }
    }

    private func beginReplay(_ url: URL, settings s: EngineSettings, speed: Double) {
        stopInternal()
        do {
            let recording = try LoadedRecording.load(url)
            settings = s
            let layout = recording.metadata.map { PilotLayout(pilots: $0.pilots) } ?? s.layout
            let pipeline = GesturePipeline(
                sampleRate: recording.sampleRate, channels: recording.channels.count, layout: layout, detector: s.detector,
                fusion: s.fusion, interaction: s.interaction)
            pipeline.wantsDisplay = wantsDisplay
            self.pipeline = pipeline
            replay = ReplayState(
                recording: recording, speed: max(0.1, speed), startedAt: Self.now(),
                inputs: (recording.metadata?.inputTimes ?? []).sorted())
            status = .replaying(progress: 0)
            startTimer()
        } catch {
            fail("Could not open \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func stopInternal() {
        let wasActive = pipeline != nil || status.isActive
        timer?.cancel()
        timer = nil
        endRecording()
        pilot?.stop()
        capture?.stop()
        pilot = nil
        capture = nil
        pipeline = nil
        replay = nil
        idleMonitor = nil
        silentSince = nil
        micSilent = false
        lastNotedInput = -Double.infinity
        if status.isActive { status = .stopped }
        if wasActive { deliver() }
    }

    private func fail(_ message: String) {
        status = .failed(message)
        deliver()
    }

    private func apply(_ s: EngineSettings) {
        let old = settings
        settings = s
        guard let pipeline else { return }
        if s.layout != old.layout, replay == nil {
            startLive(s)  // new bands: rebuild the pipeline
            return
        }
        if s.detector != old.detector { pipeline.detectorConfig = s.detector }
        if s.fusion != old.fusion { pipeline.fusionConfig = s.fusion }
        if s.interaction != old.interaction { pipeline.interactionConfig = s.interaction }
        if s.level != old.level { refreshLevel(force: true) }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: Tick

    private func tick() {
        let now = Self.now()
        if replay != nil {
            tickReplay(now)
        } else {
            tickLive(now)
        }
        if now - lastDelivery >= 1.0 / 30 { deliver() }
    }

    private func tickLive(_ now: Double) {
        guard let capture, let pipeline else { return }
        if now - lastVolumeCheck >= 0.2 {
            lastVolumeCheck = now
            refreshLevel(force: false)
        }
        if now - lastIdleCheck >= 0.05, let idle = idleMonitor?.idleSeconds() {
            lastIdleCheck = now
            inputIdle = idle
            let t = pipeline.time - idle
            if t > lastNotedInput + 0.02 {
                lastNotedInput = t
                pipeline.noteInput(at: t)
                recorder?.noteInput(at: t)
            }
        }
        let samples = capture.ring.readAvailable()
        guard let n = samples.first?.count, n > 0 else { return }
        if let recorder {
            do { try recorder.append(samples) } catch { endRecording() }
        }
        let out = pipeline.process(samples)
        handle(out)
        watchForSilence(peak: out.peak, at: pipeline.time)
    }

    private func tickReplay(_ now: Double) {
        guard var r = replay, let pipeline else { return }
        let target = min(r.recording.frameCount, Int((now - r.startedAt) * r.speed * r.recording.sampleRate))
        while r.offset < target {
            let end = min(target, r.offset + 480)
            let tEnd = Double(end) / r.recording.sampleRate
            while r.nextInput < r.inputs.count && r.inputs[r.nextInput] <= tEnd {
                pipeline.noteInput(at: r.inputs[r.nextInput])
                r.nextInput += 1
            }
            handle(pipeline.process(r.recording.channels.map { Array($0[r.offset..<end]) }))
            r.offset = end
        }
        replay = r
        status = .replaying(progress: Double(r.offset) / Double(max(1, r.recording.frameCount)))
        if r.offset >= r.recording.frameCount {
            timer?.cancel()
            timer = nil
            replay = nil
            status = .stopped
            deliver()
        }
    }

    private func handle(_ out: PipelineOutput) {
        pendingFrames += out.frames
        interactionPhase = out.interactionPhase
        // While paused the pilot is off, so anything detected is meaningless.
        guard case .paused = status else {
            pendingEvents += out.events
            pendingControls += out.controls
            out.events.forEach { recorder?.noteEvent($0) }
            return
        }
    }

    private func watchForSilence(peak: Float, at t: Double) {
        if peak >= 1e-7 {
            silentSince = nil
            if micSilent {
                micSilent = false
                status = decision.pauseReason.map { .paused($0) } ?? .running
            }
            return
        }
        if silentSince == nil { silentSince = t }
        if !micSilent, let since = silentSince, t - since > 1.5 {
            micSilent = true
            status = .failed("The microphone is delivering silence. Check Microphone access, or whether another app took exclusive use of it.")
        }
    }

    // MARK: Volume compensation

    private func readSpeakerLevel() {
        guard let speakers else { return }
        speakerGainDB = AudioDevices.volumeDecibels(speakers.id).map(Double.init)
        speakerMuted = AudioDevices.isMuted(speakers.id) ?? false
    }

    private func refreshLevel(force: Bool) {
        guard let pilot, let pipeline else { return }
        readSpeakerLevel()
        let new = settings.level.decide(speakerGainDB: speakerGainDB, muted: speakerMuted)
        guard force || new != decision else { return }
        let old = decision
        decision = new
        if let amplitude = new.amplitudeDBFS {
            pilot.setAmplitude(Self.linear(amplitude))
            // Volume changes are compensated, so the tone's acoustic level stays put: keep the baselines
            // (resetting them on every step would blind the detector while someone dials the volume).
            if old.amplitudeDBFS == nil {
                pilot.setTones(Self.tones(for: pipeline))
                pipeline.resetBaselines()
            }
            if case .paused = status { status = .running }
        } else {
            pilot.setTones([])
            if !micSilent { status = .paused(new.pauseReason ?? "Paused") }
        }
    }

    // MARK: Recording

    private func beginRecording(directory: URL, label: String?) {
        guard recorder == nil, let capture, let pipeline else { return }
        var meta = RecordingMetadata(
            sampleRate: capture.sampleRate, channels: capture.channels,
            pilots: pipeline.bands.map(\.pilotHz), micDevice: capture.device.name,
            machine: MachineInfo.current().summary)
        meta.amplitudeDBFS = decision.amplitudeDBFS
        meta.speakerGainDB = speakerGainDB
        meta.detector = settings.detector
        meta.label = label
        do {
            recorder = try RecordingWriter(directory: directory, metadata: meta, streamStart: pipeline.time)
        } catch {
            fail("Could not start recording: \(error.localizedDescription)")
        }
    }

    private func endRecording() {
        guard let recorder else { return }
        self.recorder = nil
        savedRecording = try? recorder.finish()
    }

    // MARK: Output

    private func deliver() {
        lastDelivery = Self.now()
        var out = EngineOutput()
        out.frames = deliverAllFrames ? pendingFrames : Array(pendingFrames.suffix(1))
        out.events = pendingEvents
        out.controls = pendingControls
        out.interactionPhase = interactionPhase
        out.status = status
        out.bands = pipeline?.bands ?? []
        out.displayHalfWidth = pipeline?.displayHalfWidth ?? 64
        out.amplitudeDBFS = replay == nil ? decision.amplitudeDBFS : nil
        out.speakerGainDB = speakerGainDB
        out.speakerMuted = speakerMuted
        out.inputIdle = inputIdle
        out.droppedFrames = capture?.ring.droppedFrames ?? 0
        out.recordingURL = recorder?.url
        out.savedRecording = savedRecording
        pendingFrames = []
        pendingEvents = []
        pendingControls = []
        savedRecording = nil
        onOutput(out)
    }

    // MARK: Helpers

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    private static func linear(_ dB: Double) -> Float { Float(pow(10, dB / 20)) }
    /// Single layout: the tone on both speakers. Stereo: left pilot on the left speaker only, right on the right.
    private static func tones(for pipeline: GesturePipeline) -> [PilotTone] {
        guard pipeline.layout.isStereo, pipeline.bands.count == 2 else {
            return pipeline.bands.map { PilotTone(frequency: $0.pilotHz) }
        }
        return [PilotTone(frequency: pipeline.bands[0].pilotHz, leftGain: 1, rightGain: 0),
                PilotTone(frequency: pipeline.bands[1].pilotHz, leftGain: 0, rightGain: 1)]
    }
}
