import Foundation
import WaveCore

/// Everything the user can change, persisted as JSON in UserDefaults. Decoding is tolerant: missing keys
/// (from older versions) fall back to defaults.
struct WavePreferences: Codable, Equatable {
    var enabled = true
    var sensitivity = 0.5
    /// Only run the sonar while some app is playing audio (plus a grace period afterwards).
    var onlyWhileMediaPlaying = true
    /// Keep listening this long after playback stops, so a push can resume what a push paused.
    var mediaGraceMinutes = 3.0
    /// Apps whose audio output doesn't count as "media playing" (bundle-ID prefixes).
    var ignoredMediaApps: [String] = []
    var showHUD = true

    /// Push-only mode: one tone on both speakers.
    var pushPilotHz = 19_000.0
    /// Swipe mode (experimental): two tones, one per speaker.
    var swipesEnabled = false
    var leftPilotHz = 18_750.0
    var rightPilotHz = 19_250.0
    /// Pilot level at the reference speaker volume (50 %).
    var levelDBFS = -8.0

    var mapping = GestureMapping()
    /// Hold your hand still in front of the screen, then slide closer/farther to adjust.
    var dialEnabled = true
    /// What the dial adjusts; holding still switches to the next one.
    var dialTargets: [DialTarget] = [.volume, .brightness]
    /// Level change per push / pull while hovering (%).
    var dialStep = 10.0
    /// Close your raised hand into a fist.
    var grabEnabled = true
    var calibration: CalibrationProfile?
    var hasCompletedOnboarding = false
    var debugRecordingsEnabled = false

    init() {}

    init(from decoder: Decoder) throws {
        let d = WavePreferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        enabled = v(.enabled, d.enabled)
        sensitivity = v(.sensitivity, d.sensitivity)
        onlyWhileMediaPlaying = v(.onlyWhileMediaPlaying, d.onlyWhileMediaPlaying)
        mediaGraceMinutes = v(.mediaGraceMinutes, d.mediaGraceMinutes)
        ignoredMediaApps = v(.ignoredMediaApps, d.ignoredMediaApps)
        showHUD = v(.showHUD, d.showHUD)
        pushPilotHz = v(.pushPilotHz, d.pushPilotHz)
        swipesEnabled = v(.swipesEnabled, d.swipesEnabled)
        leftPilotHz = v(.leftPilotHz, d.leftPilotHz)
        rightPilotHz = v(.rightPilotHz, d.rightPilotHz)
        // 19.5 kHz from one speaker proved too weak; move the old default pair to 18.75 / 19.25 kHz.
        if rightPilotHz == 19_500 && leftPilotHz == 18_750 { rightPilotHz = 19_250 }
        levelDBFS = v(.levelDBFS, d.levelDBFS)
        mapping = v(.mapping, d.mapping)
        dialEnabled = v(.dialEnabled, d.dialEnabled)
        dialTargets = v(.dialTargets, d.dialTargets)
        dialStep = v(.dialStep, d.dialStep)
        grabEnabled = v(.grabEnabled, d.grabEnabled)
        calibration = try? c.decodeIfPresent(CalibrationProfile.self, forKey: .calibration)
        hasCompletedOnboarding = v(.hasCompletedOnboarding, d.hasCompletedOnboarding)
        debugRecordingsEnabled = v(.debugRecordingsEnabled, d.debugRecordingsEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, sensitivity, onlyWhileMediaPlaying, mediaGraceMinutes, ignoredMediaApps, showHUD, pushPilotHz, swipesEnabled
        case leftPilotHz, rightPilotHz, levelDBFS, mapping, calibration, hasCompletedOnboarding, debugRecordingsEnabled
        case dialEnabled, dialTargets, dialStep, grabEnabled
    }

    // MARK: Persistence

    private static let key = "WavePreferences.v1"

    static func load() -> WavePreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(WavePreferences.self, from: data)
        else { return WavePreferences() }
        return prefs
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    // MARK: Engine settings

    var pilotLayout: PilotLayout {
        swipesEnabled ? .stereo(left: leftPilotHz, right: rightPilotHz) : .single(pushPilotHz)
    }

    var engineSettings: EngineSettings {
        var s = EngineSettings()
        s.layout = pilotLayout
        s.level.referenceAmplitudeDBFS = levelDBFS
        if let calibration, calibration.layout == pilotLayout {
            s.detector = calibration.detector
            s.fusion = calibration.fusion
            if let i = calibration.interaction { s.interaction = i }
        }
        s.detector.sensitivity = sensitivity
        s.interaction.dialEnabled = dialEnabled && !dialTargets.isEmpty
        s.interaction.dialTargets = max(1, dialTargets.count)
        s.interaction.dialStep = dialStep / 100
        s.interaction.grabEnabled = grabEnabled
        return s
    }
}

/// Which action each gesture triggers.
struct GestureMapping: Codable, Equatable {
    var push: GestureAction = .media(.playPause)
    var swipeLeft: GestureAction = .media(.previous)
    var swipeRight: GestureAction = .media(.next)
    var grab: GestureAction = .system(.minimizeWindow)
    var pull: GestureAction = .none

    init(push: GestureAction = .media(.playPause), swipeLeft: GestureAction = .media(.previous),
         swipeRight: GestureAction = .media(.next), grab: GestureAction = .system(.minimizeWindow),
         pull: GestureAction = .none) {
        self.push = push
        self.swipeLeft = swipeLeft
        self.swipeRight = swipeRight
        self.grab = grab
        self.pull = pull
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decodeIfPresent(GestureAction.self, forKey: .push) { push = v }
        if let v = try? c.decodeIfPresent(GestureAction.self, forKey: .swipeLeft) { swipeLeft = v }
        if let v = try? c.decodeIfPresent(GestureAction.self, forKey: .swipeRight) { swipeRight = v }
        if let v = try? c.decodeIfPresent(GestureAction.self, forKey: .grab) { grab = v }
        if let v = try? c.decodeIfPresent(GestureAction.self, forKey: .pull) { pull = v }
    }

    private enum CodingKeys: String, CodingKey { case push, swipeLeft, swipeRight, grab, pull }

    subscript(kind: GestureEvent.Kind) -> GestureAction {
        get {
            switch kind {
            case .push: return push
            case .swipeLeft: return swipeLeft
            case .swipeRight: return swipeRight
            case .grab: return grab
            case .pull: return pull
            }
        }
        set {
            switch kind {
            case .push: push = newValue
            case .swipeLeft: swipeLeft = newValue
            case .swipeRight: swipeRight = newValue
            case .grab: grab = newValue
            case .pull: pull = newValue
            }
        }
    }
}
