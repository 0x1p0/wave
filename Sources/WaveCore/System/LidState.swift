import Foundation
import IOKit

/// Whether the MacBook's lid is closed (clamshell mode with an external display, or about to sleep).
/// With the lid closed the built-in speakers and mics are covered, so Wave pauses.
public enum LidState {
    public static func isClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        else { return nil }
        return (value as? Bool) ?? (value as? NSNumber)?.boolValue
    }
}
