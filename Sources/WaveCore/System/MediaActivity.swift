import CoreAudio
import Foundation

/// Is anything (other than Wave) playing audio right now?
///
/// macOS 14.2+ exposes Core Audio "process objects": one per client process, with whether it is
/// currently running output. That lets Wave ignore its own pilot. On 14.0–14.1 it falls back to
/// "the default output device is running and it isn't the built-in speakers".
public enum MediaActivity {
    /// Processes (bundle IDs, or "pid N") currently producing audio output, excluding `excludingPID`.
    /// nil when it can't be determined.
    /// `ignoring` matches bundle-ID prefixes (so "org.example.app" also ignores its helper processes).
    public static func activeOutputProcesses(excludingPID: pid_t = getpid(), ignoring: Set<String> = []) -> [String]? {
        if #available(macOS 14.2, *) {
            let system = AudioObjectID(kAudioObjectSystemObject)
            let objects = CAProperty.array(system, CAProperty.address(kAudioHardwarePropertyProcessObjectList), zero: AudioObjectID(0))
            var active: [String] = []
            for object in objects {
                let pid = CAProperty.value(object, CAProperty.address(kAudioProcessPropertyPID), initial: pid_t(0)) ?? 0
                guard pid != excludingPID else { continue }
                let running = CAProperty.value(object, CAProperty.address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0)) ?? 0
                guard running != 0 else { continue }
                let bundle = CAProperty.string(object, CAProperty.address(kAudioProcessPropertyBundleID))
                active.append(bundle.flatMap { $0.isEmpty ? nil : $0 } ?? "pid \(pid)")
            }
            return active.filter { id in !ignoring.contains { id.hasPrefix($0) } }
        }
        guard let output = AudioDevices.defaultOutputID(),
              output != AudioDevices.builtInSpeakers()?.id,
              let running = CAProperty.value(output, CAProperty.address(kAudioDevicePropertyDeviceIsRunningSomewhere), initial: UInt32(0))
        else { return nil }
        return running != 0 ? ["default output"] : []
    }

    /// The app a helper process belongs to (best effort: strips ".helper…" suffixes).
    public static func owningApp(of bundleID: String) -> String {
        if let r = bundleID.range(of: ".helper", options: .caseInsensitive) { return String(bundleID[..<r.lowerBound]) }
        return bundleID
    }
}
