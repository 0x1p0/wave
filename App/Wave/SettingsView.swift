import AppKit
import ServiceManagement
import SwiftUI
import WaveCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag(AppModel.SettingsTab.general)
            GestureSettings(model: model).tabItem { Label("Gestures", systemImage: "hand.wave") }.tag(AppModel.SettingsTab.gestures)
            SoundSettings(model: model).tabItem { Label("Sound", systemImage: "speaker.wave.2") }.tag(AppModel.SettingsTab.sound)
            CalibrationSettings(model: model).tabItem { Label("Calibration", systemImage: "tuningfork") }.tag(AppModel.SettingsTab.calibration)
            AdvancedSettings(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag(AppModel.SettingsTab.advanced)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 560)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Wave is on", isOn: $model.prefs.enabled)
                LabeledContent("Sensitivity") {
                    HStack {
                        Text("Strict").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $model.prefs.sensitivity, in: 0...1)
                        Text("Sensitive").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Show a confirmation on screen for each gesture", isOn: $model.prefs.showHUD)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.loginItemStatus == .enabled },
                    set: { model.setLaunchAtLogin($0) }))
                if model.loginItemStatus == .requiresApproval {
                    Text("Approve Wave in System Settings → General → Login Items.").font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Only listen while media is playing") {
                Toggle("Only listen while media is playing", isOn: $model.prefs.onlyWhileMediaPlaying)
                Stepper(value: $model.prefs.mediaGraceMinutes, in: 0...30, step: 1) {
                    Text("Keep listening \(Int(model.prefs.mediaGraceMinutes)) min after playback stops")
                }
                .disabled(!model.prefs.onlyWhileMediaPlaying)
                if model.prefs.onlyWhileMediaPlaying {
                    if model.mediaApps.isEmpty {
                        Text("Nothing is playing right now.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(Set(model.mediaApps.map(MediaActivity.owningApp(of:)))).sorted(), id: \.self) { app in
                            HStack {
                                Text("Playing: \(app)").font(.caption)
                                Spacer()
                                Button("Ignore") { model.prefs.ignoredMediaApps.append(app) }.controlSize(.small)
                            }
                        }
                    }
                    ForEach(model.prefs.ignoredMediaApps, id: \.self) { app in
                        HStack {
                            Text("Ignored: \(app)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { model.prefs.ignoredMediaApps.removeAll { $0 == app } }.controlSize(.small)
                        }
                    }
                }
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", detail: "to hear the tone's echo",
                              granted: model.micPermission == .authorized,
                              action: model.micPermission == .notDetermined ? "Allow" : "Open Settings") {
                    if model.micPermission == .notDetermined {
                        model.requestMicrophone()
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                PermissionRow(title: "Accessibility", detail: "to send media keys and keyboard shortcuts",
                              granted: model.accessibilityTrusted, action: "Open Settings") {
                    model.requestAccessibility()
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button(action, action: perform) }
        }
    }
}

// MARK: - Gestures

struct GestureSettings: View {
    @Bindable var model: AppModel
    @State private var shortcuts: [String] = []

    var body: some View {
        Form {
            Section {
                GestureRow(kind: .push, action: $model.prefs.mapping.push, shortcuts: shortcuts) { model.perform(.push) }
                GestureRow(kind: .pull, action: $model.prefs.mapping.pull, shortcuts: shortcuts) { model.perform(.pull) }
            } header: {
                HStack {
                    Text("Gestures")
                    Spacer()
                    Button("Practice them…") { model.showTutorial() }.buttonStyle(.link).font(.callout)
                }
            }

            Section("Swipes") {
                Toggle(isOn: $model.prefs.swipesEnabled) {
                    SettingLabel("Swipe left and right", "Plays a separate tone on each speaker. Calibrate after turning this on.")
                }
                if model.prefs.swipesEnabled {
                    GestureRow(kind: .swipeLeft, action: $model.prefs.mapping.swipeLeft, shortcuts: shortcuts) { model.perform(.swipeLeft) }
                    GestureRow(kind: .swipeRight, action: $model.prefs.mapping.swipeRight, shortcuts: shortcuts) { model.perform(.swipeRight) }
                    LabeledContent("Quick setup") {
                        HStack(spacing: 6) {
                            Button("Desktops") {
                                model.prefs.mapping.swipeLeft = .system(.nextDesktop)
                                model.prefs.mapping.swipeRight = .system(.previousDesktop)
                            }
                            .help("Like a trackpad: swiping left brings in the desktop on the right")
                            Button("Tracks") {
                                model.prefs.mapping.swipeLeft = .media(.previous)
                                model.prefs.mapping.swipeRight = .media(.next)
                            }
                            Button("YouTube ±10 s") {
                                model.prefs.mapping.swipeLeft = .key(.youTubeBack10)
                                model.prefs.mapping.swipeRight = .key(.youTubeForward10)
                            }
                        }
                        .controlSize(.small)
                    }
                    if [model.prefs.mapping.swipeLeft, model.prefs.mapping.swipeRight].contains(where: { $0 == .system(.nextDesktop) || $0 == .system(.previousDesktop) }) {
                        Text("Desktop switching uses ⌃← and ⌃→ — keep them on in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Fist") {
                Toggle(isOn: $model.prefs.grabEnabled) {
                    SettingLabel("Close your hand into a fist", "Hold an open hand up, then close it quickly and firmly. Taps on the desk don't count.")
                }
                if model.prefs.grabEnabled {
                    GestureRow(kind: .grab, action: $model.prefs.mapping.grab, shortcuts: shortcuts) { model.perform(.grab) }
                }
            }

            Section("Hover controls") {
                Toggle(isOn: $model.prefs.dialEnabled) {
                    SettingLabel("Volume and brightness by hovering",
                                 "Bring your hand up and hold it really still until ✋ appears, then push for ＋ and pull for −. Hold still to switch control; move away to finish.")
                }
                if model.prefs.dialEnabled {
                    Picker("Controls", selection: $model.prefs.dialTargets) {
                        Text("Volume, then brightness").tag([DialTarget.volume, .brightness])
                        Text("Brightness, then volume").tag([DialTarget.brightness, .volume])
                        Text("Volume only").tag([DialTarget.volume])
                        Text("Brightness only").tag([DialTarget.brightness])
                    }
                    Picker("Each push or pull changes it by", selection: $model.prefs.dialStep) {
                        Text("5 %").tag(5.0)
                        Text("10 %").tag(10.0)
                        Text("20 %").tag(20.0)
                    }
                    if !BrightnessController.isAvailable {
                        Text("Smooth brightness isn't available on this Mac; brightness changes in key-sized steps.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            if !model.accessibilityTrusted {
                Section {
                    PermissionRow(title: "Accessibility", detail: "Media keys and keyboard shortcuts need it",
                                  granted: false, action: "Open Settings") { model.requestAccessibility() }
                }
            }
        }
        .formStyle(.grouped)
        .task { shortcuts = await ShortcutsRunner.list() }
    }
}

/// A setting's title with a one-line explanation under it.
struct SettingLabel: View {
    let title: String
    let detail: String
    init(_ title: String, _ detail: String) { self.title = title; self.detail = detail }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One gesture: what it is, how to do it, what it does, and a button to try the action.
struct GestureRow: View {
    let kind: GestureEvent.Kind
    @Binding var action: GestureAction
    let shortcuts: [String]
    let test: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                GestureBadge(symbol: kind.symbol, tint: kind.tint, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title)
                    Text(kind.howTo).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ActionMenu(action: $action, shortcuts: shortcuts)
                    .frame(width: 210)
                Button(action: test) { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .disabled(action == .none)
                    .help("Try it: runs the action now, as if you had made the gesture")
            }
            switch action {
            case .key(let combo):
                HStack {
                    Spacer()
                    Text("Keys sent to the front app").font(.caption).foregroundStyle(.secondary)
                    KeyRecorder(combo: Binding(get: { combo }, set: { action = .key($0) }))
                        .frame(width: 140, height: 24)
                }
            case .shortcut(let name) where shortcuts.isEmpty:
                HStack {
                    Spacer()
                    TextField("Name of a shortcut in the Shortcuts app", text: Binding(get: { name }, set: { action = .shortcut($0) }))
                        .frame(width: 300)
                }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }
}

/// Every action in one menu, grouped: media, windows & desktops, volume & brightness, keys and Shortcuts.
struct ActionMenu: View {
    @Binding var action: GestureAction
    let shortcuts: [String]

    private static let windowActions: [SystemAction] = [.minimizeWindow, .closeWindow, .hideApp, .nextDesktop, .previousDesktop,
                                                         .missionControl, .appWindows, .lockScreen]
    private static let levelActions: [SystemAction] = [.volumeUp, .volumeDown, .brightnessUp, .brightnessDown]

    var body: some View {
        Picker("", selection: $action) {
            Label("Nothing", systemImage: "circle.slash").tag(GestureAction.none)
            Section("Media") {
                ForEach(MediaKey.allCases) { Label($0.title, systemImage: $0.symbol).tag(GestureAction.media($0)) }
            }
            Section("Windows and desktops") {
                ForEach(Self.windowActions) { Label($0.title, systemImage: $0.symbol).tag(GestureAction.system($0)) }
            }
            Section("Volume and brightness") {
                ForEach(Self.levelActions) { Label($0.title, systemImage: $0.symbol).tag(GestureAction.system($0)) }
            }
            Section("Other") {
                Label("Keyboard shortcut…", systemImage: "keyboard").tag(keyTag)
                ForEach(shortcutNames, id: \.self) { name in
                    Label("Shortcut “\(name)”", systemImage: "square.stack.3d.up.fill").tag(GestureAction.shortcut(name))
                }
                if shortcuts.isEmpty {
                    Label("Shortcut…", systemImage: "square.stack.3d.up.fill").tag(shortcutTag)
                }
            }
        }
        .labelsHidden()
    }

    /// The current keyboard shortcut if one is set, else Space (then recorded in the row).
    private var keyTag: GestureAction {
        if case .key = action { return action }
        return .key(.space)
    }

    private var shortcutTag: GestureAction {
        if case .shortcut = action { return action }
        return .shortcut("")
    }

    private var shortcutNames: [String] {
        var names = shortcuts
        if case .shortcut(let n) = action, !n.isEmpty, !names.contains(n) { names.append(n) }
        return names
    }
}

/// Click, then press a key combination to record it. Esc cancels.
struct KeyRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onRecord = { combo = $0 }
        v.combo = combo
        return v
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onRecord = { combo = $0 }
        view.combo = combo
    }

    final class RecorderView: NSView {
        var combo: KeyCombo? { didSet { needsDisplay = true } }
        var onRecord: ((KeyCombo) -> Void)?
        private var recording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            recording = true
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { return super.keyDown(with: event) }
            if event.keyCode == 53 {  // Esc
                recording = false
                return
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let display = KeyCombo.describe(keyCode: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers)
            let new = KeyCombo(keyCode: event.keyCode, modifiers: flags.rawValue, display: display)
            combo = new
            onRecord?(new)
            recording = false
            window?.makeFirstResponder(nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            let text = recording ? "Press keys…" : (combo?.display ?? "Click to record")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
    }
}

// MARK: - Sound

struct SoundSettings: View {
    @Bindable var model: AppModel
    @State private var hearing: HearingTest?

    var body: some View {
        Form {
            Section("MacBook speakers") {
                LabeledContent("Volume") {
                    HStack {
                        if let v = model.speakerVolume { Text("\(Int((v * 100).rounded())) %") }
                        if let g = model.speakerGainDB { Text(String(format: "(%.1f dB)", g)).foregroundStyle(.secondary) }
                        if model.speakerMuted { Text("muted").foregroundStyle(.orange) }
                    }
                }
                if model.speakersTooQuiet {
                    HStack {
                        Text("Too quiet for Wave. Volume keys only change your current output, so this sets the MacBook speakers directly.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Set to 50 %") { model.setSpeakers(to: 0.5) }
                    }
                }
                if let a = model.amplitudeDBFS {
                    LabeledContent("Pilot now", value: String(format: "%.1f dBFS (compensated for volume)", a))
                }
            }
            Section("Tone") {
                if model.prefs.swipesEnabled {
                    Picker("Left speaker", selection: $model.prefs.leftPilotHz) { frequencyOptions }
                    Picker("Right speaker", selection: $model.prefs.rightPilotHz) { frequencyOptions }
                } else {
                    Picker("Frequency", selection: $model.prefs.pushPilotHz) { frequencyOptions }
                }
                LabeledContent("Level at 50 % volume") {
                    HStack {
                        Slider(value: $model.prefs.levelDBFS, in: -20 ... -2, step: 1)
                        Text(String(format: "%.0f dBFS", model.prefs.levelDBFS)).monospacedDigit().frame(width: 70)
                    }
                }
                Text("Higher tones are less likely to be heard but echo more weakly on this Mac (it measured best at 18.75–19.25 kHz).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Can you hear the tone?") {
                if let hearing {
                    HearingTestView(test: hearing) { self.hearing = nil }
                } else {
                    Button("Run hearing test…") { hearing = HearingTest(model: model) }
                    Text("Plays Wave's tone for a few seconds. If you can hear it, Wave moves to a higher one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var frequencyOptions: some View {
        ForEach([18_500.0, 18_750, 19_000, 19_250, 19_500], id: \.self) { f in
            Text(String(format: "%.2f kHz", f / 1000)).tag(f)
        }
    }
}

// MARK: - Calibration

struct CalibrationSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Your calibration") {
                if let c = model.prefs.calibration {
                    LabeledContent("Measured", value: c.created.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Tones", value: c.layout.description)
                    Text(c.summary).font(.caption).foregroundStyle(.secondary)
                    if c.layout != model.prefs.pilotLayout {
                        Text("The tones changed since this calibration, so default thresholds are in use. Calibrate again.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Reset to defaults", role: .destructive) { model.prefs.calibration = nil }
                } else {
                    Text("Not calibrated: using default thresholds.").foregroundStyle(.secondary)
                }
                Button("Calibrate…") { model.showCalibration() }
                Text("Measures the room for a few seconds, then asks for 5 pushes (and 5 swipes each way if swipes are on), and sets the thresholds for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Training data") {
                Button("Record labeled samples…") { model.showSampleRecorder() }
                Text("Saves windows of gesture features (no audio) as JSON and CSV for training a Core ML classifier later.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

struct AdvancedSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Debugging") {
                Button("Open debug window…") { model.showDebugWindow() }
                Text("Live spectrogram, detector traces and an event log. Its Record button saves raw microphone audio (.caf) for replay — the only time Wave ever writes audio to disk.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show recordings folder") {
                    let url = RecordingWriter.defaultDirectory
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                }
            }
            Section {
                if model.recentEvents.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentEvents.prefix(8)) { e in
                        HStack(spacing: 8) {
                            Image(systemName: e.isAccepted ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(e.isAccepted ? .green : .secondary)
                            Text(e.summary).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(e.isAccepted ? .primary : .secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recent detections")
                    Spacer()
                    Button("Open full log") { NSWorkspace.shared.open(DetectionLog.shared.url) }
                        .buttonStyle(.link).font(.callout)
                }
            } footer: {
                Text("✗ lines are motions Wave noticed and ignored — nothing happened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Wave analyses the microphone signal in memory, on your Mac. Audio never leaves the Mac and is never saved, except recordings you start yourself in the debug window. Wave keeps a small text log of detections (no audio) for troubleshooting. The orange microphone dot in the menu bar is on whenever Wave is listening.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
