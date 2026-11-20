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
    var rightPilotHz = 19_500.0
    /// Pilot level at the reference speaker volume (50 %).
    var levelDBFS = -8.0

    var mapping = GestureMapping()
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
        levelDBFS = v(.levelDBFS, d.levelDBFS)
        mapping = v(.mapping, d.mapping)
        calibration = try? c.decodeIfPresent(CalibrationProfile.self, forKey: .calibration)
        hasCompletedOnboarding = v(.hasCompletedOnboarding, d.hasCompletedOnboarding)
        debugRecordingsEnabled = v(.debugRecordingsEnabled, d.debugRecordingsEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, sensitivity, onlyWhileMediaPlaying, mediaGraceMinutes, ignoredMediaApps, showHUD, pushPilotHz, swipesEnabled
        case leftPilotHz, rightPilotHz, levelDBFS, mapping, calibration, hasCompletedOnboarding, debugRecordingsEnabled
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
        }
        s.detector.sensitivity = sensitivity
        return s
    }
}

/// Which action each gesture triggers.
struct GestureMapping: Codable, Equatable {
    var push: GestureAction = .media(.playPause)
    var swipeLeft: GestureAction = .media(.previous)
    var swipeRight: GestureAction = .media(.next)

    subscript(kind: GestureEvent.Kind) -> GestureAction {
        get {
            switch kind {
            case .push: return push
            case .swipeLeft: return swipeLeft
            case .swipeRight: return swipeRight
            }
        }
        set {
            switch kind {
            case .push: push = newValue
            case .swipeLeft: swipeLeft = newValue
            case .swipeRight: swipeRight = newValue
            }
        }
    }
}
