import AppKit
import AVFoundation
import Foundation
import Observation
import ServiceManagement
import WaveCore
import WaveUI

/// Central app state: preferences, the sonar engine, when it may run, and what gestures do.
@MainActor
@Observable
final class AppModel {
    enum Mode: Equatable {
        case normal
        /// Guided calibration owns the engine (no actions fire, runs regardless of media).
        case calibrating
        /// Labeled-sample recorder owns the engine (no actions fire).
        case sampling
        /// The hearing test plays tones directly; the engine is off.
        case hearingTest
        /// The debug window runs its own engine; gestures still trigger actions.
        case debugWindow
        /// The gesture tutorial owns the engine (practice: no actions).
        case tutorial
    }

    var prefs: WavePreferences {
        didSet {
            guard prefs != oldValue else { return }
            prefs.save()
            preferencesChanged(from: oldValue)
        }
    }

    // MARK: Observed state
    private(set) var mode: Mode = .normal
    private(set) var engineStatus: EngineStatus = .stopped
    /// Why the engine isn't running right now (nil = it should be running).
    private(set) var gateReason: String?
    private(set) var micPermission: AVAuthorizationStatus = MicCapture.permission
    private(set) var accessibilityTrusted = Accessibility.isTrusted
    private(set) var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    private(set) var mediaApps: [String] = []
    private(set) var speakerGainDB: Double?
    private(set) var speakerVolume: Float?
    private(set) var speakerMuted = false
    private(set) var amplitudeDBFS: Double?
    private(set) var lastGesture: (kind: GestureEvent.Kind, action: GestureAction, at: Date)?
    private(set) var recentEvents: [GestureEvent] = []

    // MARK: Collaborators
    @ObservationIgnored private(set) var engine: SonarEngine!
    @ObservationIgnored let system = SystemStateMonitor()
    @ObservationIgnored let hud = HUDController()
    @ObservationIgnored let windows = WindowManager()
    @ObservationIgnored private(set) var debugModel: DebugModel?
    /// Calibration / sample recorder see every frame, event and control while they own the engine.
    @ObservationIgnored var frameSink: ((EngineOutput) -> Void)?
    /// Hold-and-slide state.
    @ObservationIgnored private var dialTarget: DialTarget?
    @ObservationIgnored private var dialLevel: Float?
    @ObservationIgnored private var interactionActive = false
    @ObservationIgnored private var modeSettings: EngineSettings?
    @ObservationIgnored private var engineRunning = false
    @ObservationIgnored private var runningSettings: EngineSettings?
    @ObservationIgnored private var mediaLastActive: Date?
    @ObservationIgnored private var lastGestureDate: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0

    init() {
        prefs = WavePreferences.load()
        engine = SonarEngine { [weak self] output in
            let model = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model?.ingest(output) }
            }
        }
        engine.setFrameDelivery(all: false)
        system.onChange = { [weak self] in self?.reevaluate() }
    }

    // MARK: Lifecycle

    func launch() {
        readSpeakers()
        pollMedia()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if !prefs.hasCompletedOnboarding {
            showOnboarding()
        }
        reevaluate()
    }

    func shutdown() {
        debugModel?.shutdown()
        engine.stopAndWait()
    }

    private func poll() {
        tick += 1
        let trusted = Accessibility.isTrusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        let mic = MicCapture.permission
        if mic != micPermission { micPermission = mic; reevaluate() }
        if tick % 2 == 0 { pollMedia() }
        if tick % 5 == 0 {
            let s = SMAppService.mainApp.status
            if s != loginItemStatus { loginItemStatus = s }
        }
        if !engineRunning { readSpeakers() }
    }

    private func readSpeakers() {
        guard let spk = AudioDevices.builtInSpeakers() else { return }
        let gain = AudioDevices.volumeDecibels(spk.id).map(Double.init)
        let volume = AudioDevices.volumeScalar(spk.id)
        let muted = AudioDevices.isMuted(spk.id) ?? false
        if gain != speakerGainDB { speakerGainDB = gain }
        if volume != speakerVolume { speakerVolume = volume }
        if muted != speakerMuted { speakerMuted = muted }
    }

    private func pollMedia() {
        guard prefs.onlyWhileMediaPlaying else { return }
        let apps = MediaActivity.activeOutputProcesses(ignoring: Set(prefs.ignoredMediaApps))
        let list = apps ?? []
        if list != mediaApps { mediaApps = list }
        if apps == nil || !list.isEmpty { mediaLastActive = Date() }
        reevaluate()
    }

    // MARK: Gating

    /// Whether media counts as active: playing now, or within the grace period after playback stopped
    /// or after a gesture (so a push can resume what a push paused).
    private var mediaWindowOpen: Bool {
        let grace = prefs.mediaGraceMinutes * 60
        let now = Date()
        if let t = mediaLastActive, now.timeIntervalSince(t) < max(grace, 2.5) { return true }
        if let t = lastGestureDate, now.timeIntervalSince(t) < grace { return true }
        return false
    }

    func reevaluate() {
        let reason: String? = {
            switch mode {
            case .hearingTest: return "Hearing test in progress"
            case .debugWindow: return "Debug window is listening"
            case .calibrating, .sampling, .tutorial:
                if micPermission != .authorized { return "Microphone access needed" }
                return system.pauseReason
            case .normal:
                if !prefs.enabled { return "Off" }
                if micPermission != .authorized { return "Microphone access needed" }
                if let r = system.pauseReason { return r }
                if prefs.onlyWhileMediaPlaying && !mediaWindowOpen { return "Waiting for media to play" }
                return nil
            }
        }()
        if reason != gateReason {
            gateReason = reason
            DetectionLog.shared.write(reason.map { "PAUSED: \($0)" } ?? "LISTENING")
        }
        let settings = modeSettings ?? prefs.engineSettings
        if reason == nil {
            if !engineRunning {
                DetectionLog.shared.write("ENGINE START  \(settings.layout.description)")
                engineRunning = true
                runningSettings = settings
                engine.start(settings)
            } else if settings != runningSettings {
                runningSettings = settings
                engine.update(settings)
            }
        } else if engineRunning {
            engineRunning = false
            runningSettings = nil
            engine.stop()
            endInteraction()
        }
    }

    private func preferencesChanged(from old: WavePreferences) {
        if prefs.onlyWhileMediaPlaying != old.onlyWhileMediaPlaying || prefs.ignoredMediaApps != old.ignoredMediaApps {
            pollMedia()
        }
        reevaluate()
        if prefs.pilotLayout != old.pilotLayout, let debugModel {
            debugModel.baseSettings = prefs.engineSettings
        }
    }

    // MARK: Engine output

    private func ingest(_ out: EngineOutput) {
        if out.status != engineStatus {
            engineStatus = out.status
            if out.status != .running { endInteraction() }
        }
        if out.amplitudeDBFS != amplitudeDBFS { amplitudeDBFS = out.amplitudeDBFS }
        if let g = out.speakerGainDB, g != speakerGainDB { speakerGainDB = g }
        if out.speakerMuted != speakerMuted { speakerMuted = out.speakerMuted }
        frameSink?(out)
        for e in out.events { handle(e) }
        if mode == .normal { out.controls.forEach(handleControl) }
    }

    // MARK: Hold & slide (volume / brightness) and grab

    func handleControl(_ control: ControlEvent) {
        DetectionLog.shared.write("HOVER \(control)")
        let targets = prefs.dialEnabled ? prefs.dialTargets : []
        switch control {
        case .ready(let i), .targetChanged(let i):
            interactionActive = true
            dialTarget = targets.indices.contains(i) ? targets[i] : nil
            dialLevel = dialTarget?.get()
            showDialHUD()
        case .adjust(let i, let delta):
            guard targets.indices.contains(i) else { return }
            let target = targets[i]
            if dialTarget != target { dialTarget = target; dialLevel = target.get() }
            let wanted = min(1, max(0, (dialLevel ?? 0.5) + Float(delta)))
            dialLevel = target.set(wanted) ?? wanted
            lastGestureDate = Date()  // keeps "only while media plays" listening
            showDialHUD()
        case .ended:
            endInteraction()
        }
    }

    /// Clears the ✋ overlay (also when the engine stops mid-interaction and no `.ended` will come).
    private func endInteraction() {
        if interactionActive { hud.hide(after: 0.6) }
        interactionActive = false
        dialTarget = nil
        dialLevel = nil
    }

    private func showDialHUD() {
        guard prefs.showHUD else { return }
        if let target = dialTarget {
            var hints = [HUDHint(gesture: "Push", effect: "＋"), HUDHint(gesture: "Pull", effect: "−")]
            if let other = prefs.dialTargets.first(where: { $0 != target }) {
                hints.append(HUDHint(gesture: "Hold still", effect: other.title))
            }
            hints.append(HUDHint(gesture: "Move away", effect: "done"))
            hud.show(symbol: target.symbol, title: target.title, subtitle: "Hover control", level: dialLevel,
                     tint: target.tint, hints: hints, sticky: true)
        } else if prefs.grabEnabled {
            hud.show(symbol: "hand.raised.fill", title: "Ready", subtitle: "Make a fist: \(prefs.mapping.grab.title)",
                     tint: GestureEvent.Kind.grab.tint, sticky: true)
        }
    }

    private func handle(_ e: GestureEvent) {
        recentEvents.insert(e, at: 0)
        if recentEvents.count > 50 { recentEvents.removeLast() }
        let acts = e.isAccepted && (mode == .normal || mode == .debugWindow)
        DetectionLog.shared.write(e.summary + (acts ? "  → \(prefs.mapping[e.kind].title)" : "")
                                  + (mode == .normal ? "" : "  [\(mode)]"))
        guard acts else { return }
        perform(e.kind)
    }

    func perform(_ kind: GestureEvent.Kind) {
        let action = prefs.mapping[kind]
        lastGestureDate = Date()
        lastGesture = (kind, action, Date())
        switch ActionPerformer.perform(action) {
        case .done:
            if prefs.showHUD, action != .none {
                hud.show(symbol: action.symbol, title: action.title, subtitle: kind.title, tint: kind.tint)
            }
        case .level(let level):
            if prefs.showHUD {
                hud.show(symbol: action.symbol, title: action.title, subtitle: kind.title, level: level, tint: kind.tint)
            }
        case .needsAccessibility:
            hud.show(symbol: "exclamationmark.triangle.fill", title: "Wave needs Accessibility",
                     subtitle: "To press media keys — click the Wave menu to grant it", tint: .orange)
        case .failed(let message):
            hud.show(symbol: "exclamationmark.triangle.fill", title: "Couldn't run that", subtitle: message, tint: .orange)
        }
    }

    // MARK: Modes (calibration, samples, hearing test, debug)

    /// Takes the engine for calibration/sample recording with the given settings.
    func beginExclusive(_ mode: Mode, settings: EngineSettings, sink: @escaping (EngineOutput) -> Void) {
        self.mode = mode
        modeSettings = settings
        frameSink = sink
        engine.setFrameDelivery(all: true)
        if engineRunning {
            engineRunning = false
            engine.stop()  // restart cleanly with the new settings (fresh baseline)
        }
        reevaluate()
    }

    func updateExclusive(settings: EngineSettings) {
        modeSettings = settings
        reevaluate()
    }

    func endExclusive() {
        frameSink = nil
        modeSettings = nil
        engine.setFrameDelivery(all: false)
        mode = .normal
        if engineRunning {
            engineRunning = false
            engine.stop()
        }
        reevaluate()
    }

    func beginHearingTest() {
        mode = .hearingTest
        reevaluate()
    }

    func endHearingTest() {
        mode = .normal
        reevaluate()
    }

    // MARK: Permissions & system

    func requestMicrophone() {
        Task {
            _ = await MicCapture.requestPermission()
            micPermission = MicCapture.permission
            reevaluate()
        }
    }

    func requestAccessibility() {
        Accessibility.requestTrust()
        Accessibility.openSettings()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if on { SMAppService.openSystemSettingsLoginItems() }
        }
        loginItemStatus = SMAppService.mainApp.status
    }

    /// Explicit user action only (a button): sets the MacBook speakers' own volume and unmutes them.
    func setSpeakers(to volume: Float) {
        guard let spk = AudioDevices.builtInSpeakers() else { return }
        try? AudioDevices.setVolumeScalar(spk.id, volume)
        try? AudioDevices.setMuted(spk.id, false)
        readSpeakers()
    }

    var speakersTooQuiet: Bool {
        if speakerMuted { return true }
        guard let g = speakerGainDB else { return false }
        return g < prefs.engineSettings.level.minimumSpeakerGainDB
    }

    // MARK: Status for the menu

    var statusText: String {
        if let gate = gateReason { return gate }
        switch engineStatus {
        case .running: return "Listening · " + prefs.pilotLayout.description
        case .paused(let reason): return reason
        case .failed(let reason): return reason
        case .stopped: return "Starting…"
        case .replaying: return "Replaying"
        }
    }

    enum Health { case listening, idle, off, problem }

    var health: Health {
        if mode == .normal && !prefs.enabled { return .off }
        if micPermission == .denied || micPermission == .restricted { return .problem }
        if gateReason != nil { return .idle }
        switch engineStatus {
        case .running: return .listening
        case .failed: return .problem
        case .paused: return speakersTooQuiet ? .problem : .idle
        default: return .idle
        }
    }

    var menuSymbol: String {
        switch health {
        case .listening: return "hand.wave.fill"
        case .idle: return "hand.wave"
        case .off: return "hand.raised.slash"
        case .problem: return "exclamationmark.triangle"
        }
    }

    // MARK: Windows

    /// Plausible state for UI snapshots (a recent gesture), without listening.
    func prepareForSnapshot() {
        lastGesture = (.swipeLeft, prefs.mapping.swipeLeft, Date().addingTimeInterval(-2))
    }

    enum SettingsTab: Hashable { case general, gestures, sound, calibration, advanced }
    /// Which Settings tab is showing (the menu's "Change…" jumps to Gestures).
    var settingsTab: SettingsTab = .general

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        windows.show(.settings, title: "Wave Settings", size: NSSize(width: 660, height: 600)) {
            SettingsView(model: self)
        }
    }

    func showOnboarding() {
        windows.show(.onboarding, title: "Welcome to Wave", size: NSSize(width: 620, height: 520)) {
            OnboardingView(model: self)
        }
    }

    func showCalibration() {
        let session = CalibrationSession(model: self)
        windows.show(.calibration, title: "Calibrate Wave", size: NSSize(width: 560, height: 460),
                     onClose: { [weak session] in session?.cancel() }) {
            CalibrationView(session: session)
        }
    }

    func showSampleRecorder() {
        let recorder = SampleRecorderModel(model: self)
        windows.show(.samples, title: "Labeled Samples", size: NSSize(width: 520, height: 420),
                     onClose: { [weak recorder] in recorder?.stop() }) {
            SampleRecorderView(recorder: recorder)
        }
    }

    func showTutorial() {
        var lessons: [Lesson.Kind] = [.sonar, .push, .pull]
        if prefs.dialEnabled { lessons.append(.hover) }
        if prefs.grabEnabled { lessons.append(.grab) }
        if prefs.swipesEnabled { lessons.append(.swipe) }
        var settings = prefs.engineSettings
        settings.interaction.pullEnabled = true  // the Pull lesson needs pulls even when Pull does nothing
        let tutorial = TutorialModel(lessons: lessons, grabSnapDB: settings.interaction.grabSnapDB,
                                     onThresholdDB: settings.detector.effectiveOnDB,
                                     dialTargetNames: prefs.dialTargets.map(\.title))
        windows.show(.tutorial, title: "Learn Wave gestures", size: NSSize(width: 940, height: 680),
                     onClose: { [weak self] in
                        guard let self, self.mode == .tutorial else { return }
                        self.endExclusive()
                     }) {
            TutorialView(model: tutorial) { [weak self] in self?.windows.close(.tutorial) }
        }
        beginExclusive(.tutorial, settings: settings) { [weak tutorial] out in
            tutorial?.ingest(frames: out.frames, events: out.events, controls: out.controls, phase: out.interactionPhase)
        }
    }

    func showDebugWindow() {
        let debug = DebugModel()
        debug.baseSettings = prefs.engineSettings
        debug.amplitudeDBFS = prefs.levelDBFS
        debug.sensitivity = prefs.sensitivity
        debug.onEvent = { [weak self] e in
            guard let self else { return }
            self.recentEvents.insert(e, at: 0)
            if e.isAccepted { self.perform(e.kind) }
        }
        debug.onControl = { [weak self] c in self?.handleControl(c) }
        debugModel = debug
        mode = .debugWindow
        reevaluate()  // stops the app's engine
        windows.show(.debug, title: "Wave Debug", size: NSSize(width: 1120, height: 820), resizable: true,
                     onClose: { [weak self] in
                        self?.debugModel?.shutdown()
                        self?.debugModel = nil
                        self?.mode = .normal
                        self?.reevaluate()
                     }) {
            DebugWindowView(model: debug)
        }
        // Give the app engine a moment to fade its pilot out before the debug engine starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { debug.start() }
    }
}

extension GestureEvent.Kind {
    var title: String {
        switch self {
        case .push: return "Push"
        case .swipeLeft: return "Swipe left"
        case .swipeRight: return "Swipe right"
        case .grab: return "Fist"
        case .pull: return "Pull"
        }
    }

    var symbol: String {
        switch self {
        case .push: return "hand.raised.fill"
        case .swipeLeft: return "hand.point.left.fill"
        case .swipeRight: return "hand.point.right.fill"
        case .grab: return "hand.raised.fingers.spread.fill"
        case .pull: return "arrow.uturn.backward"
        }
    }

    /// How to do it, in a few words.
    var howTo: String {
        switch self {
        case .push: return "Toward the screen and back"
        case .pull: return "From close up, flick back toward you"
        case .swipeLeft: return "Across the laptop, right → left"
        case .swipeRight: return "Across the laptop, left → right"
        case .grab: return "Open hand, then a quick firm fist"
        }
    }
}
