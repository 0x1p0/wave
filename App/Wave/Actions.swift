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

    var title: String {
        switch self {
        case .none: return "Nothing"
        case .media(let k): return k.title
        case .key(let combo): return "Key \(combo.display)"
        case .shortcut(let name): return "Shortcut “\(name)”"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "circle.slash"
        case .media(let k): return k.symbol
        case .key: return "keyboard"
        case .shortcut: return "square.stack.3d.up.fill"
        }
    }

    /// Media and keyboard actions are posted as system events, which needs Accessibility.
    var needsAccessibility: Bool {
        switch self {
        case .media, .key: return true
        case .none, .shortcut: return false
        }
    }
}

/// Performs gesture actions.
@MainActor
enum ActionPerformer {
    enum Result { case done, needsAccessibility, failed(String) }

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
        }
    }

    /// Media keys are NX_SYSDEFINED events (subtype 8) with the key in data1.
    private static func postMediaKey(_ key: MediaKey) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 8, data1: (key.rawValue << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private static func postKey(_ combo: KeyCombo) {
        let source = CGEventSource(stateID: .hidSystemState)
        var flags = CGEventFlags()
        let m = combo.flags
        if m.contains(.command) { flags.insert(.maskCommand) }
        if m.contains(.option) { flags.insert(.maskAlternate) }
        if m.contains(.control) { flags.insert(.maskControl) }
        if m.contains(.shift) { flags.insert(.maskShift) }
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
