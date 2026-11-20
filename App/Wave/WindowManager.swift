import AppKit
import SwiftUI

/// Regular AppKit windows hosting SwiftUI views. (A menu bar app has no window scenes of its own to
/// open from AppKit callbacks, so it manages these itself.)
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    enum Kind: String { case settings, onboarding, calibration, debug, samples, tutorial }

    private var windows: [Kind: NSWindow] = [:]
    private var onClose: [Kind: () -> Void] = [:]

    func isOpen(_ kind: Kind) -> Bool { windows[kind] != nil }

    func show<V: View>(_ kind: Kind, title: String, size: NSSize, resizable: Bool = false,
                       onClose: (() -> Void)? = nil, @ViewBuilder content: () -> V) {
        if let existing = windows[kind] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Wave.\(kind.rawValue)")
        windows[kind] = window
        if let onClose { self.onClose[kind] = onClose }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ kind: Kind) { windows[kind]?.close() }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key else { return }
        windows[kind] = nil
        let callback = onClose.removeValue(forKey: kind)
        callback?()
    }
}
