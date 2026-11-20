import Foundation
import IOKit

/// Time since the last keyboard/trackpad/mouse event, from IOHIDSystem's HIDIdleTime.
/// Needs no permission (unlike event taps / Input Monitoring).
public final class InputIdleMonitor {
    private var service: io_service_t = 0

    public init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// Seconds since the last HID input, or nil if unavailable.
    public func idleSeconds() -> Double? {
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
        else { return nil }
        if let number = value as? NSNumber {
            return Double(number.uint64Value) / 1_000_000_000
        }
        if let data = value as? Data, data.count >= 8 {
            let ns = data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            return Double(ns) / 1_000_000_000
        }
        return nil
    }
}
