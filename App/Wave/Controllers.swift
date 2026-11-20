import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import WaveCore

/// What the hold-and-slide dial adjusts.
enum DialTarget: String, Codable, CaseIterable, Identifiable {
    case volume, brightness
    var id: String { rawValue }

    var title: String { self == .volume ? "Volume" : "Brightness" }
    var symbol: String { self == .volume ? "speaker.wave.2.fill" : "sun.max.fill" }

    @MainActor func get() -> Float? {
        self == .volume ? VolumeController.get() : BrightnessController.get()
    }

    /// Sets the level; returns the level actually applied.
    @MainActor @discardableResult func set(_ value: Float) -> Float? {
        self == .volume ? VolumeController.set(value) : BrightnessController.set(value)
    }
}

/// Volume of whatever the system is playing through (AirPods, speakers, …), via Core Audio.
@MainActor
enum VolumeController {
    static func output() -> AudioObjectID? { AudioDevices.defaultOutputID() }

    static func get() -> Float? {
        guard let id = output() else { return nil }
        return AudioDevices.volumeScalar(id)
    }

    /// Never takes the MacBook speakers below the level Wave needs to keep hearing its tone.
    static func set(_ value: Float) -> Float? {
        guard let id = output() else { return nil }
        let old = AudioDevices.volumeScalar(id)
        let v = min(1, max(0, value))
        try? AudioDevices.setVolumeScalar(id, v)
        if v > 0, AudioDevices.isMuted(id) == true { try? AudioDevices.setMuted(id, false) }
        if id == AudioDevices.builtInSpeakers()?.id, let old, v < old,
           let gain = AudioDevices.volumeDecibels(id), Double(gain) < PilotLevelPolicy().minimumSpeakerGainDB {
            try? AudioDevices.setVolumeScalar(id, old)
            return old
        }
        return AudioDevices.volumeScalar(id)
    }

    static func step(_ delta: Float) -> Float? {
        guard let v = get() else { return nil }
        return set(v + delta)
    }
}

/// Built-in display brightness via DisplayServices (a private Apple framework, loaded at runtime), with
/// the brightness keys as a fallback.
@MainActor
enum BrightnessController {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn: GetFn? = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var isAvailable: Bool { getFn != nil && setFn != nil && builtInDisplay != nil }

    static func get() -> Float? {
        guard let getFn, let display = builtInDisplay else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) -> Float? {
        guard let setFn, let display = builtInDisplay else { return nil }
        _ = setFn(display, min(1, max(0.02, value)))
        return get()
    }

    static func step(_ delta: Float) -> Float? {
        if let v = get() { return set(v + delta) }
        ActionPerformer.postSystemKey(delta > 0 ? 2 : 3)  // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        return nil
    }
}
