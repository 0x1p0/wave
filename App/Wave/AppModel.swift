import AppKit
import ApplicationServices
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
    /// Gestures acted on today (for the menu).
    private(set) var gesturesToday = 0
    @ObservationIgnored private var gesturesDay = Calendar.current.startOfDay(for: Date())
    /// Wave is snoozed (not listening) until then.
    private(set) var snoozedUntil: Date?

    /// Stops listening for a while; it comes back by itself.
    func snooze(for seconds: TimeInterval?) {
        snoozedUntil = seconds.map { Date().addingTimeInterval($0) }
        reevaluate()
        if let until = snoozedUntil {
            DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow + 0.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let s = self.snoozedUntil, s <= Date() else { return }
                    self.snoozedUntil = nil
                    self.reevaluate()
                }
            }
        }
    }
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
        system.onUnlock = { [weak self] in self?.welcomeBack(how: "unlocked") }
    }

    // MARK: Lifecycle

    func launch() {
        readSpeakers()
        pollMedia()
        followFrontApp()
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
        refreshFrontSite()  // so the menu shows "YouTube in Brave" while you watch
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
                if let until = snoozedUntil, until > Date() {
                    return "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
                }
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
        if mode == .normal {
            out.controls.forEach(handleControl)
            followHoverPhase(out.interactionPhase)
            out.presence.forEach(handlePresence)
            out.air.forEach(handleAir)
        }
    }

    // MARK: Air letters

    /// Teaching a letter: the next drawings become its examples.
    private(set) var teaching: (letter: AirLetter, count: Int)?
    /// The last drawing, for Settings ("Recognised W → opened Spotify").
    private(set) var lastAirResult: (text: String, good: Bool, at: Date)?
    @ObservationIgnored private var heldGestures: [GestureEvent.Kind] = []
    @ObservationIgnored private var drawingInProgress = false
    static let examplesPerLetter = 3

    /// Air letters are listening (two tones needed), with something to recognise or teach.
    var airLettersActive: Bool {
        prefs.airLettersEnabled && prefs.swipesEnabled && (!prefs.airLetters.isEmpty || teaching != nil)
    }

    func startTeaching(name: String, appID: String, appName: String) {
        teaching = (AirLetter(name: name, appID: appID, appName: appName), 0)
        lastAirResult = nil
    }

    func cancelTeaching() { teaching = nil }

    func deleteLetter(_ id: UUID) { prefs.airLetters.removeAll { $0.id == id } }

    private func holdGesture(_ kind: GestureEvent.Kind) {
        heldGestures.append(kind)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated { self?.releaseHeld() }
        }
    }

    /// Acts on held gestures, unless a drawing is still going on (then they wait for it).
    private func releaseHeld() {
        guard !drawingInProgress, !heldGestures.isEmpty else { return }
        let due = heldGestures
        heldGestures = []
        due.forEach(perform)
    }

    private func handleAir(_ event: AirWriterEvent) {
        switch event {
        case .drawingStarted:
            if airLettersActive { drawingInProgress = true }
        case .drawingAbandoned:
            drawingInProgress = false
            releaseHeld()
        case .drawn(let drawing):
            drawingInProgress = false
            if var t = teaching {
                heldGestures = []
                t.letter.examples.append(drawing.shape)
                t.count += 1
                DetectionLog.shared.write(String(format: "AIR taught %@ example %d (%.1f s)", t.letter.name, t.count, drawing.duration))
                if t.count >= Self.examplesPerLetter {
                    prefs.airLetters.removeAll { $0.name == t.letter.name }
                    prefs.airLetters.append(t.letter)
                    teaching = nil
                    lastAirResult = ("Learned \(t.letter.name) → \(t.letter.appName). Draw it to try.", true, Date())
                } else {
                    teaching = t
                }
                return
            }
            guard prefs.airLettersEnabled, !prefs.airLetters.isEmpty else { releaseHeld(); return }
            if let m = AirWriter.match(drawing, in: prefs.airLetters) {
                heldGestures = []
                DetectionLog.shared.write(String(format: "AIR %@ (%.0f%%) → open %@", m.letter.name, m.score * 100, m.letter.appName))
                lastAirResult = ("Recognised \(m.letter.name) (\(Int(m.score * 100)) %) → opened \(m.letter.appName)", true, Date())
                open(m.letter)
            } else {
                DetectionLog.shared.write(String(format: "AIR drawing %.1f s matched no letter", drawing.duration))
                lastAirResult = ("That drawing didn't match a letter", false, Date())
                releaseHeld()
            }
        }
    }

    private func open(_ letter: AirLetter) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: letter.appID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        lastGesture = (.push, .shortcut(letter.appName), Date())
        gesturesToday += 1
        if prefs.showHUD {
            hud.show(symbol: "scribble.variable", title: "Opening \(letter.appName)", subtitle: "Air letter “\(letter.name)”", tint: .purple)
        }
    }

    // MARK: Walk away / come back

    /// Wave paused what was playing when you left, so it should resume it when you're back.
    @ObservationIgnored private var pausedForAbsence = false
    /// For the menu and Settings: when Wave last thought you left.
    private(set) var awaySince: Date?

    private func handlePresence(_ event: PresenceEvent) {
        DetectionLog.shared.write("PRESENCE \(event)")
        guard prefs.presenceEnabled else { return }
        switch event {
        case .left:
            awaySince = Date()
            if !mediaApps.isEmpty, case .done = ActionPerformer.perform(.media(.playPause)) {
                pausedForAbsence = true
            }
            if prefs.presenceLocks { _ = ActionPerformer.perform(.system(.lockScreen)) }
        case .returned:
            welcomeBack(how: "came back")
        case .maybeLeaving, .stillHere:
            break
        }
    }

    /// You're back (moved in, typed, or unlocked): resume what Wave paused when you left.
    private func welcomeBack(how: String) {
        guard awaySince != nil || pausedForAbsence else { return }
        awaySince = nil
        DetectionLog.shared.write("PRESENCE welcome back (\(how))\(pausedForAbsence ? ", resuming" : "")")
        guard pausedForAbsence else { return }
        pausedForAbsence = false
        _ = ActionPerformer.perform(.media(.playPause))
        if prefs.showHUD {
            hud.show(symbol: "hand.wave.fill", title: "Welcome back", subtitle: "Resumed what was playing", tint: .green)
        }
    }

    // MARK: "Hold still…" feedback

    @ObservationIgnored private var hoverPhase: InteractionDetector.Phase = .idle
    @ObservationIgnored private var holdingSince: Date?
    @ObservationIgnored private var holdHUDShown = false

    /// While Wave waits for a raised hand to settle, a ring fills up so you can see it noticed you. It only
    /// appears after 0.35 s of stillness: shorter pauses (between swipes) shouldn't flash it.
    private func followHoverPhase(_ phase: InteractionDetector.Phase) {
        defer { hoverPhase = phase }
        guard prefs.showHUD, prefs.dialEnabled || prefs.grabEnabled else { return }
        if phase == .holding {
            if hoverPhase != .holding { holdingSince = Date() }
            guard !holdHUDShown, let since = holdingSince, Date().timeIntervalSince(since) >= 0.35, !interactionActive else { return }
            holdHUDShown = true
            let hold = (prefs.engineSettings.interaction.holdDelay) - Date().timeIntervalSince(since)
            hud.show(symbol: "hand.raised.fill", title: "Hold still…",
                     subtitle: prefs.dialEnabled ? "Opening \(prefs.dialTargets.first?.title.lowercased() ?? "volume")" : "Then make a fist",
                     tint: .pink, holdUntil: Date().addingTimeInterval(max(0.1, hold)), sticky: true)
        } else {
            holdingSince = nil
            if holdHUDShown {
                holdHUDShown = false
                if phase != .ready && !interactionActive { hud.hide(after: 0.15) }
            }
        }
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
            var hints = [HUDHint(gesture: "Quick push", effect: "＋"), HUDHint(gesture: "Quick pull", effect: "−")]
            if let other = prefs.dialTargets.first(where: { $0 != target }) {
                hints.append(HUDHint(gesture: "Then swipe", effect: other.title))
            }
            if prefs.grabEnabled { hints.append(HUDHint(gesture: "Fist", effect: prefs.mapping.grab.shortTitle)) }
            hud.show(symbol: target.symbol, title: target.title, subtitle: "Closes by itself when you stop", level: dialLevel,
                     tint: target.tint, hints: hints, sticky: true)
        } else if prefs.grabEnabled {
            hud.show(symbol: "hand.raised.fill", title: "Ready", subtitle: "Make a fist: \(prefs.mapping.grab.title)",
                     tint: GestureEvent.Kind.grab.tint, sticky: true)
        }
    }

    private func handle(_ e: GestureEvent) {
        recentEvents.insert(e, at: 0)
        if recentEvents.count > 50 { recentEvents.removeLast() }
        var acts = e.isAccepted && (mode == .normal || mode == .debugWindow)
        if acts && teaching != nil { acts = false }  // teaching a letter: gestures don't act
        if acts && airLettersActive && [.push, .swipeLeft, .swipeRight].contains(e.kind) {
            // It might be the start of a letter: wait a moment (and until any drawing ends) before acting.
            holdGesture(e.kind)
            DetectionLog.shared.write(e.summary + "  (held: could be an air letter)")
            return
        }
        DetectionLog.shared.write(e.summary + (acts ? "  → \(effectiveAction(for: e.kind).title)" : "")
                                  + (acts && smartPreset(for: e.kind) != nil ? " (smart, \(smartPlace ?? ""))" : "")
                                  + (mode == .normal ? "" : "  [\(mode)]"))
        guard acts else { return }
        perform(e.kind)
    }

    // MARK: Smart mode: swipes follow the app you're in

    /// The app you're using: the last one in front that isn't Wave.
    private(set) var frontApp: (id: String, name: String, pid: pid_t)?
    /// A website smart mode recognised in that app's front window (a browser showing YouTube).
    private(set) var frontSite: (id: String, name: String, mode: String)?
    @ObservationIgnored private var frontAppObserver: NSObjectProtocol?

    private func followFrontApp() {
        func take(_ app: NSRunningApplication?) {
            guard let app, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
            frontApp = (id, app.localizedName ?? id, app.processIdentifier)
        }
        take(NSWorkspace.shared.frontmostApplication)
        frontAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
                self.frontApp = (id, app.localizedName ?? id, app.processIdentifier)
                self.refreshFrontSite()
            }
        }
    }

    /// Looks at the front browser window's title for a site smart mode knows (YouTube). Needs Accessibility,
    /// which Wave already has for sending keys; reads only the title.
    func refreshFrontSite() {
        guard prefs.smartMode, let app = frontApp,
              SmartModes.mode(for: app.id, overrides: [:]) == "browser" || prefs.appModes[app.id] == "browser",
              let title = Self.focusedWindowTitle(pid: app.pid) else {
            if frontSite != nil { frontSite = nil }
            return
        }
        let site = SmartModes.site(inTitle: title)
        if site?.id != frontSite?.id {
            frontSite = site
            DetectionLog.shared.write("SITE " + (site.map { "\($0.name) in \(app.name)" } ?? "none in \(app.name)"))
        }
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    /// The swipe mode smart mode picks for the app in front (nil: your own gestures). In a browser showing a
    /// site it knows (YouTube), the site's mode wins.
    func smartPreset(for kind: GestureEvent.Kind? = nil) -> GesturePreset? {
        if let kind, kind != .swipeLeft && kind != .swipeRight { return nil }  // smart mode only changes swipes
        guard prefs.smartMode, let app = frontApp,
              let id = SmartModes.mode(for: app.id, overrides: prefs.appModes) else { return nil }
        if id == "browser", let site = frontSite {
            let siteMode = prefs.siteModes[site.id] ?? site.mode
            if siteMode != "default", let preset = GesturePreset.named(siteMode) { return preset }
        }
        return GesturePreset.named(id)
    }

    /// Where smart mode is acting: "Brave Browser" or "YouTube in Brave Browser".
    var smartPlace: String? {
        guard let app = frontApp else { return nil }
        return frontSite.map { "\($0.name) in \(app.name)" } ?? app.name
    }

    /// What a gesture does right now, in the app you're in.
    func effectiveAction(for kind: GestureEvent.Kind) -> GestureAction {
        smartPreset(for: kind)?.action(for: kind) ?? prefs.mapping[kind]
    }

    /// Sets the swipe mode for the app in front (smart mode) or for everywhere (otherwise).
    func chooseSwipeMode(_ preset: GesturePreset) {
        if prefs.smartMode, let site = frontSite {
            prefs.siteModes[site.id] = preset.id
        } else if prefs.smartMode, let app = frontApp {
            prefs.appModes[app.id] = preset.id
        } else {
            preset.apply(to: &prefs.mapping)
        }
    }

    /// The swipe mode in use right now (nil when your own swipes don't match any mode).
    var currentSwipeMode: GesturePreset? {
        smartPreset(for: .swipeLeft) ?? GesturePreset.all.first { $0.matches(prefs.mapping) }
    }

    /// The last push and what it did, to recognise "push twice".
    @ObservationIgnored private var lastPush: (at: Date, action: GestureAction)?

    /// Push twice within this long: screenshot.
    static let doublePushWindow: TimeInterval = 1.3

    /// Second push in quick succession: take a screenshot, then undo what the first push did if it was a toggle
    /// (play/pause), so the music isn't left paused. The first push acted immediately — no waiting.
    private func performDoublePush(firstAction: GestureAction) {
        lastPush = nil
        let shot = GestureAction.system(.screenshot)
        _ = ActionPerformer.perform(shot)
        if firstAction == .media(.playPause) || firstAction == .key(.space) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { _ = ActionPerformer.perform(firstAction) }
        }
        lastGesture = (.push, shot, Date())
        gesturesToday += 1
        DetectionLog.shared.write("PUSH ×2 → Screenshot")
        if prefs.showHUD {
            hud.show(symbol: "camera.viewfinder", title: "Screenshot", subtitle: "Push twice · saved to the Desktop", tint: .blue)
        }
    }

    func perform(_ kind: GestureEvent.Kind) {
        if kind == .swipeLeft || kind == .swipeRight { refreshFrontSite() }
        if kind == .push, prefs.doublePushScreenshot, let last = lastPush,
           Date().timeIntervalSince(last.at) < Self.doublePushWindow {
            performDoublePush(firstAction: last.action)
            return
        }
        let action = effectiveAction(for: kind)
        if kind == .push { lastPush = (Date(), action) } else { lastPush = nil }
        lastGestureDate = Date()
        lastGesture = (kind, action, Date())
        let today = Calendar.current.startOfDay(for: Date())
        if today != gesturesDay { gesturesDay = today; gesturesToday = 0 }
        gesturesToday += 1
        switch ActionPerformer.perform(action) {
        case .done:
            if prefs.showHUD, action != .none {
                let place = smartPreset(for: kind) != nil ? " · \(smartPlace ?? "")" : ""
                hud.show(symbol: action.symbol, title: action.title, subtitle: kind.title + place, tint: kind.tint)
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

    /// Plausible state for UI snapshots (listening, permissions granted, a recent gesture in a browser),
    /// without actually listening.
    func prepareForSnapshot() {
        engineStatus = .running
        micPermission = .authorized
        accessibilityTrusted = true
        gesturesToday = 18
        if let brave = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser") {
            frontApp = ("com.brave.Browser", FileManager.default.displayName(atPath: brave.path).replacingOccurrences(of: ".app", with: ""), 0)
        }
        lastGesture = (.swipeLeft, effectiveAction(for: .swipeLeft), Date().addingTimeInterval(-2))
    }

    enum SettingsTab: Hashable { case gestures, apps, letters, hover, general, sound, calibration, advanced }
    /// Which Settings page is showing (the menu's "Change…" jumps to Gestures).
    var settingsTab: SettingsTab = .gestures

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { settingsTab = tab }
        windows.show(.settings, title: "Wave Settings", size: NSSize(width: 880, height: 680), resizable: true) {
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
