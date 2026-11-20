import Foundation
import WaveCore

/// `wave-probe speakers [--volume PCT | --mute]`: shows or sets the *built-in speakers'* own volume and
/// mute, without making them the default output (so whatever you're listening to stays on your headphones).
/// Only runs when you ask; the Wave app itself never changes volume.
enum SpeakersCommand {
    static func run(volumePercent: Double?, mute: Bool, uid: String?) throws -> Int32 {
        let device = try DeviceOverrides(outputUID: uid).speakers()
        let before = Environment.speakerState(device).summary
        print("\(device.name): \(before)")
        guard volumePercent != nil || mute else { return 0 }

        if mute {
            try AudioDevices.setMuted(device.id, true)
        } else if let pct = volumePercent {
            let value = Float(min(100, max(0, pct)) / 100)
            try AudioDevices.setVolumeScalar(device.id, value)
            try AudioDevices.setMuted(device.id, value == 0)
        }
        Thread.sleep(forTimeInterval: 0.1)  // property changes are applied asynchronously
        print("  → now \(Environment.speakerState(device).summary)")
        if AudioDevices.defaultOutputID() != device.id {
            print("  (Your default output is still \(AudioDevices.defaultOutputID().flatMap(AudioDevices.device(id:))?.name ?? "another device"); only the pilot uses the speakers.)")
        }
        return 0
    }
}
