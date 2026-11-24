import Foundation
import CoreGraphics
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

    /// Seconds since you last typed, clicked or scrolled. Plain pointer movement doesn't count: a hand resting
    /// on the trackpad nudges the pointer constantly, and treating that as "busy" blocked most gestures made
    /// with the other hand. Falls back to all input (HIDIdleTime) if the per-type times aren't available.
    public func activeSeconds() -> Double? {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let times = types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .filter { $0.isFinite && $0 >= 0 }
        return times.min() ?? idleSeconds()
    }

    /// Seconds since the last HID input of any kind (including pointer movement), or nil if unavailable.
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
