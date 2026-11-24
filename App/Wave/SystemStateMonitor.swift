import AppKit
import Foundation
import WaveCore

/// Watches for conditions in which Wave must not listen: screen locked, displays asleep, Mac asleep,
/// lid closed, or another user's session in front.
@MainActor
final class SystemStateMonitor {
    private(set) var screenLocked = false
    private(set) var displaysAsleep = false
    private(set) var systemSleeping = false
    private(set) var lidClosed = false
    private(set) var sessionInactive = false

    var onChange: (() -> Void)?
    /// Someone unlocked the screen (for "welcome back").
    var onUnlock: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []
    private var lidTimer: Timer?

    var pauseReason: String? {
        if systemSleeping { return "Mac is asleep" }
        if lidClosed { return "Lid is closed" }
        if screenLocked { return "Screen is locked" }
        if displaysAsleep { return "Display is asleep" }
        if sessionInactive { return "Another user is active" }
        return nil
    }

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.screenLocked = true }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.screenLocked = false; $0.onUnlock?() }
        observe(workspace, NSWorkspace.screensDidSleepNotification.rawValue) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification.rawValue) { $0.displaysAsleep = false }
        observe(workspace, NSWorkspace.willSleepNotification.rawValue) { $0.systemSleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification.rawValue) { $0.systemSleeping = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification.rawValue) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) { $0.sessionInactive = false }

        lidClosed = LidState.isClosed() ?? false
        // No notification for the clamshell state; polling the IORegistry is cheap.
        lidTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let closed = LidState.isClosed(), closed != self.lidClosed else { return }
                self.lidClosed = closed
                self.onChange?()
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: String, _ update: @escaping @Sendable @MainActor (SystemStateMonitor) -> Void) {
        tokens.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                self.onChange?()
            }
        })
    }
}
