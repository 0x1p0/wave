import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// System media keys (NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h).
enum MediaKey: Int, Codable, CaseIterable, Identifiable {
    case playPause = 16
    case next = 17
    case previous = 18
    case fastForward = 19
    case rewind = 20
    case volumeUp = 0
    case volumeDown = 1
    case mute = 7

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .playPause: return "Play/Pause"
        case .next: return "Next track"
        case .previous: return "Previous track"
        case .fastForward: return "Fast forward"
        case .rewind: return "Rewind"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute"
        }
    }

    var symbol: String {
        switch self {
        case .playPause: return "playpause.fill"
        case .next: return "forward.end.fill"
        case .previous: return "backward.end.fill"
        case .fastForward: return "forward.fill"
        case .rewind: return "backward.fill"
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        }
    }
}

/// Built-in actions: windows, desktops, apps, tabs and pages, slides, volume and brightness.
enum SystemAction: String, Codable, CaseIterable, Identifiable {
    case minimizeWindow, closeWindow, hideApp
    case nextDesktop, previousDesktop, missionControl, appWindows
    case volumeUp, volumeDown, brightnessUp, brightnessDown
    case lockScreen
    // Browsers, documents and apps
    case nextTab, previousTab, back, forward, reopenTab, pageDown, pageUp, zoomIn, zoomOut, fullScreen
    case nextSlide, previousSlide, switchApp, spotlight, screenshot, showDesktop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .minimizeWindow: return "Minimize window"
        case .closeWindow: return "Close tab / window"
        case .hideApp: return "Hide app"
        case .nextDesktop: return "Next desktop"
        case .previousDesktop: return "Previous desktop"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App windows"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .brightnessUp: return "Brightness up"
        case .brightnessDown: return "Brightness down"
        case .lockScreen: return "Lock screen"
        case .nextTab: return "Next tab"
        case .previousTab: return "Previous tab"
        case .back: return "Back"
        case .forward: return "Forward"
        case .reopenTab: return "Reopen closed tab"
        case .pageDown: return "Page down"
        case .pageUp: return "Page up"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        case .fullScreen: return "Full screen"
        case .nextSlide: return "Next slide / item"
        case .previousSlide: return "Previous slide / item"
        case .switchApp: return "Switch to last app"
        case .spotlight: return "Spotlight"
        case .screenshot: return "Screenshot"
        case .showDesktop: return "Show desktop"
        }
    }

    var symbol: String {
        switch self {
        case .minimizeWindow: return "arrow.down.right.and.arrow.up.left"
        case .closeWindow: return "xmark.square"
        case .hideApp: return "eye.slash"
        case .nextDesktop: return "rectangle.righthalf.inset.filled.arrow.right"
        case .previousDesktop: return "rectangle.lefthalf.inset.filled.arrow.left"
        case .missionControl: return "rectangle.3.group"
        case .appWindows: return "macwindow.on.rectangle"
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        case .lockScreen: return "lock.fill"
        case .nextTab: return "arrow.right.square"
        case .previousTab: return "arrow.left.square"
        case .back: return "chevron.backward"
        case .forward: return "chevron.forward"
        case .reopenTab: return "arrow.uturn.backward.square"
        case .pageDown: return "arrow.down.doc"
        case .pageUp: return "arrow.up.doc"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        case .fullScreen: return "arrow.up.left.and.arrow.down.right"
        case .nextSlide: return "forward.frame"
        case .previousSlide: return "backward.frame"
        case .switchApp: return "arrow.left.arrow.right.square"
        case .spotlight: return "magnifyingglass"
        case .screenshot: return "camera.viewfinder"
        case .showDesktop: return "menubar.dock.rectangle"
        }
    }

    /// The keystroke for keyboard-driven actions (sent to the system / frontmost app).
    var keyCombo: KeyCombo? {
        let cmd = NSEvent.ModifierFlags.command.rawValue, ctrl = NSEvent.ModifierFlags.control.rawValue
        let shift = NSEvent.ModifierFlags.shift.rawValue
        switch self {
        case .minimizeWindow: return KeyCombo(keyCode: UInt16(kVK_ANSI_M), modifiers: cmd, display: "⌘M")
        case .closeWindow: return KeyCombo(keyCode: UInt16(kVK_ANSI_W), modifiers: cmd, display: "⌘W")
        case .hideApp: return KeyCombo(keyCode: UInt16(kVK_ANSI_H), modifiers: cmd, display: "⌘H")
        case .nextDesktop: return KeyCombo(keyCode: UInt16(kVK_RightArrow), modifiers: ctrl, display: "⌃→")
        case .previousDesktop: return KeyCombo(keyCode: UInt16(kVK_LeftArrow), modifiers: ctrl, display: "⌃←")
        case .missionControl: return KeyCombo(keyCode: UInt16(kVK_UpArrow), modifiers: ctrl, display: "⌃↑")
        case .appWindows: return KeyCombo(keyCode: UInt16(kVK_DownArrow), modifiers: ctrl, display: "⌃↓")
        case .lockScreen: return KeyCombo(keyCode: UInt16(kVK_ANSI_Q), modifiers: ctrl | cmd, display: "⌃⌘Q")
        case .nextTab: return KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: ctrl, display: "⌃⇥")
        case .previousTab: return KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: ctrl | shift, display: "⌃⇧⇥")
        case .back: return KeyCombo(keyCode: UInt16(kVK_ANSI_LeftBracket), modifiers: cmd, display: "⌘[")
        case .forward: return KeyCombo(keyCode: UInt16(kVK_ANSI_RightBracket), modifiers: cmd, display: "⌘]")
        case .reopenTab: return KeyCombo(keyCode: UInt16(kVK_ANSI_T), modifiers: cmd | shift, display: "⌘⇧T")
        case .pageDown: return KeyCombo(keyCode: UInt16(kVK_PageDown), modifiers: 0, display: "⇟")
        case .pageUp: return KeyCombo(keyCode: UInt16(kVK_PageUp), modifiers: 0, display: "⇞")
        case .zoomIn: return KeyCombo(keyCode: UInt16(kVK_ANSI_Equal), modifiers: cmd, display: "⌘+")
        case .zoomOut: return KeyCombo(keyCode: UInt16(kVK_ANSI_Minus), modifiers: cmd, display: "⌘−")
        case .fullScreen: return KeyCombo(keyCode: UInt16(kVK_ANSI_F), modifiers: ctrl | cmd, display: "⌃⌘F")
        case .nextSlide: return KeyCombo(keyCode: UInt16(kVK_RightArrow), modifiers: 0, display: "→")
        case .previousSlide: return KeyCombo(keyCode: UInt16(kVK_LeftArrow), modifiers: 0, display: "←")
        case .switchApp: return KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: cmd, display: "⌘⇥")
        case .spotlight: return KeyCombo(keyCode: UInt16(kVK_Space), modifiers: cmd, display: "⌘Space")
        case .screenshot: return KeyCombo(keyCode: UInt16(kVK_ANSI_3), modifiers: cmd | shift, display: "⌘⇧3")
        case .showDesktop: return KeyCombo(keyCode: UInt16(kVK_F11), modifiers: 0, display: "F11")
        case .volumeUp, .volumeDown, .brightnessUp, .brightnessDown: return nil
        }
    }

    var dialTarget: DialTarget? {
        switch self {
        case .volumeUp, .volumeDown: return .volume
        case .brightnessUp, .brightnessDown: return .brightness
        default: return nil
        }
    }
}

/// A keyboard shortcut to send to the frontmost app (e.g. J / L to seek ±10 s on YouTube).
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt  // NSEvent.ModifierFlags raw value (device-independent part)
    var display: String

    static let youTubeBack10 = KeyCombo(keyCode: UInt16(kVK_ANSI_J), modifiers: 0, display: "J")
    static let youTubeForward10 = KeyCombo(keyCode: UInt16(kVK_ANSI_L), modifiers: 0, display: "L")
    static let leftArrow = KeyCombo(keyCode: UInt16(kVK_LeftArrow), modifiers: 0, display: "←")
    static let rightArrow = KeyCombo(keyCode: UInt16(kVK_RightArrow), modifiers: 0, display: "→")
    static let space = KeyCombo(keyCode: UInt16(kVK_Space), modifiers: 0, display: "Space")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(.deviceIndependentFlagsMask) }

    static func describe(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        let named: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Home: "↖", kVK_End: "↘",
        ]
        if let n = named[Int(keyCode)] { return s + n }
        return s + (characters?.uppercased() ?? "#\(keyCode)")
    }
}

/// What a gesture does.
enum GestureAction: Codable, Equatable, Hashable {
    case none
    case media(MediaKey)
    case key(KeyCombo)
    /// Runs a shortcut from the Shortcuts app by name.
    case shortcut(String)
    /// Window, desktop, volume, brightness.
    case system(SystemAction)

    var title: String {
        switch self {
        case .none: return "Nothing"
        case .media(let k): return k.title
        case .key(let combo): return "Key \(combo.display)"
        case .shortcut(let name): return "Shortcut “\(name)”"
        case .system(let a): return a.title
        }
    }

    var symbol: String {
        switch self {
        case .none: return "circle.slash"
        case .media(let k): return k.symbol
        case .key: return "keyboard"
        case .shortcut: return "square.stack.3d.up.fill"
        case .system(let a): return a.symbol
        }
    }

    /// Media and keyboard actions are posted as system events, which needs Accessibility.
    var needsAccessibility: Bool {
        switch self {
        case .media, .key: return true
        case .system(let a): return a.keyCombo != nil
        case .none, .shortcut: return false
        }
    }
}

/// Performs gesture actions.
@MainActor
enum ActionPerformer {
    enum Result {
        case done
        /// Done, and here is the new level (volume/brightness) to show.
        case level(Float)
        case needsAccessibility
        case failed(String)
    }

    static func perform(_ action: GestureAction) -> Result {
        if action.needsAccessibility && !Accessibility.isTrusted { return .needsAccessibility }
        switch action {
        case .none:
            return .done
        case .media(let key):
            postMediaKey(key)
            return .done
        case .key(let combo):
            postKey(combo)
            return .done
        case .shortcut(let name):
            ShortcutsRunner.run(name)
            return .done
        case .system(let a):
            if let combo = a.keyCombo {
                postKey(combo)
                return .done
            }
            let step: Float = 1.0 / 16
            let up = a == .volumeUp || a == .brightnessUp
            let level = a.dialTarget == .volume ? VolumeController.step(up ? step : -step)
                                                : BrightnessController.step(up ? step : -step)
            return level.map { .level($0) } ?? .done
        }
    }

    /// NX_SYSDEFINED key (media keys, brightness keys).
    static func postSystemKey(_ code: Int) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 8, data1: (code << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Media keys are NX_SYSDEFINED events (subtype 8) with the key in data1.
    private static func postMediaKey(_ key: MediaKey) { postSystemKey(key.rawValue) }

    private static func postKey(_ combo: KeyCombo) {
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = CGEventFlags()
        let m = combo.flags
        if m.contains(.command) { flags.insert(.maskCommand) }
        if m.contains(.option) { flags.insert(.maskAlternate) }
        if m.contains(.control) { flags.insert(.maskControl) }
        if m.contains(.shift) { flags.insert(.maskShift) }
        // Real arrow keys carry the fn + number-pad flags; Mission Control's "move to space" hotkeys
        // (⌃← / ⌃→) only match when they're present.
        let arrows: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        if arrows.contains(Int(combo.keyCode)) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

/// Accessibility (needed to post media keys and keystrokes).
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt (once) that leads to System Settings.
    static func requestTrust() {
        // The constant's value; using the string avoids touching a mutable C global under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Runs Shortcuts-app shortcuts through the `shortcuts` command-line tool.
enum ShortcutsRunner {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    static func run(_ name: String) {
        let p = Process()
        p.executableURL = tool
        p.arguments = ["run", name]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()  // fire and forget
    }

    /// Names of the user's shortcuts.
    static func list() async -> [String] {
        await Task.detached {
            let p = Process()
            p.executableURL = tool
            p.arguments = ["list"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
        }.value
    }
}
