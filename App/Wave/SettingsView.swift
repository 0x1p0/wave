import AppKit
import ServiceManagement
import SwiftUI
import WaveCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Label("General", systemImage: "gearshape") }
            GestureSettings(model: model).tabItem { Label("Gestures", systemImage: "hand.wave") }
            SoundSettings(model: model).tabItem { Label("Sound", systemImage: "speaker.wave.2") }
            CalibrationSettings(model: model).tabItem { Label("Calibration", systemImage: "slider.horizontal.3") }
            AdvancedSettings(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .padding(16)
        .frame(minWidth: 600, minHeight: 520)
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
                Toggle(isOn: $model.prefs.swipesEnabled) {
                    VStack(alignment: .leading) {
                        Text("Swipe left / right (experimental)")
                        Text("Uses two tones, one per speaker. Calibrate after turning this on.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("What gestures do") {
                ActionPicker(title: "Push (toward the screen and back)", action: $model.prefs.mapping.push, shortcuts: shortcuts)
                if model.prefs.swipesEnabled {
                    ActionPicker(title: "Swipe left (hand moves right → left)", action: $model.prefs.mapping.swipeLeft, shortcuts: shortcuts)
                    ActionPicker(title: "Swipe right (hand moves left → right)", action: $model.prefs.mapping.swipeRight, shortcuts: shortcuts)
                }
                ActionPicker(title: "Pull (away from the screen and back)", action: $model.prefs.mapping.pull, shortcuts: shortcuts)
                if model.prefs.grabEnabled {
                    ActionPicker(title: "Grab (raise an open hand, hold, close it — experimental)", action: $model.prefs.mapping.grab, shortcuts: shortcuts)
                }
                HStack {
                    Text("Swipe presets").foregroundStyle(.secondary)
                    Spacer()
                    Button("Desktops") {
                        model.prefs.mapping.swipeLeft = .system(.nextDesktop)
                        model.prefs.mapping.swipeRight = .system(.previousDesktop)
                    }
                    .help("Like a trackpad: swipe left shows the desktop on the right")
                    Button("Tracks") {
                        model.prefs.mapping.swipeLeft = .media(.previous)
                        model.prefs.mapping.swipeRight = .media(.next)
                    }
                    Button("YouTube ±10 s") {
                        model.prefs.mapping.swipeLeft = .key(.youTubeBack10)
                        model.prefs.mapping.swipeRight = .key(.youTubeForward10)
                    }
                }
            }
            Section {
                Toggle(isOn: $model.prefs.dialEnabled) {
                    VStack(alignment: .leading) {
                        Text("Hover controls: volume and brightness")
                        Text("Bring your hand up about 20 cm from the screen and hold it until ✋ appears. Then push to turn up, pull to turn down. Hold still to switch between controls; move your hand away to finish.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.prefs.dialEnabled {
                    Picker("Controls", selection: $model.prefs.dialTargets) {
                        Text("Volume, then brightness").tag([DialTarget.volume, .brightness])
                        Text("Brightness, then volume").tag([DialTarget.brightness, .volume])
                        Text("Volume only").tag([DialTarget.volume])
                        Text("Brightness only").tag([DialTarget.brightness])
                    }
                    Picker("Step per push / pull", selection: $model.prefs.dialStep) {
                        Text("5 %").tag(5.0)
                        Text("10 %").tag(10.0)
                        Text("20 %").tag(20.0)
                    }
                    if !BrightnessController.isAvailable {
                        Text("Smooth brightness isn't available on this Mac; brightness changes in key-sized steps.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Toggle(isOn: $model.prefs.grabEnabled) {
                    VStack(alignment: .leading) {
                        Text("Grab: close your open hand into a fist, quickly (experimental)")
                        Text("Finger motion is faint on MacBook microphones. Check it in the tutorial; if the meter doesn't cross the line, use Pull instead.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.accessibilityTrusted {
                Section {
                    PermissionRow(title: "Accessibility", detail: "Media keys and keyboard shortcuts need it",
                                  granted: false, action: "Open Settings") { model.requestAccessibility() }
                }
            }
            Section {
                Button("Open the gesture tutorial…") { model.showTutorial() }
                Text("Live practice: see your hand the way Wave does, with tips when a gesture doesn't count.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Try it") {
                HStack {
                    ForEach(GestureEvent.Kind.allCases.filter { k in
                        k == .push || k == .pull || (k == .grab && model.prefs.grabEnabled)
                            || ((k == .swipeLeft || k == .swipeRight) && model.prefs.swipesEnabled)
                    }, id: \.self) { kind in
                        Button { model.perform(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                }
                Text("Runs the action as if you had made the gesture.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { shortcuts = await ShortcutsRunner.list() }
    }
}

/// Picks what one gesture does: nothing, a media key, a keyboard shortcut or a Shortcuts shortcut.
struct ActionPicker: View {
    let title: String
    @Binding var action: GestureAction
    let shortcuts: [String]

    private enum Kind: String, CaseIterable {
        case none = "Nothing", system = "Window / desktop / level", media = "Media key", key = "Keyboard shortcut", shortcut = "Shortcut"
    }

    private var kind: Binding<Kind> {
        Binding(
            get: {
                switch action {
                case .none: return .none
                case .media: return .media
                case .key: return .key
                case .shortcut: return .shortcut
                case .system: return .system
                }
            },
            set: { k in
                switch k {
                case .none: action = .none
                case .media: action = .media(.playPause)
                case .key: action = .key(.space)
                case .shortcut: action = .shortcut(shortcuts.first ?? "")
                case .system: action = .system(.minimizeWindow)
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack {
                Picker("", selection: kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 210)
                detail
                Spacer()
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var detail: some View {
        switch action {
        case .none:
            EmptyView()
        case .system(let a):
            Picker("", selection: Binding(get: { a }, set: { action = .system($0) })) {
                ForEach(SystemAction.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .labelsHidden()
            .frame(width: 200)
            if a == .nextDesktop || a == .previousDesktop {
                Text("uses ⌃← / ⌃→ (Keyboard Shortcuts → Mission Control)").font(.caption).foregroundStyle(.secondary)
            }
        case .media(let key):
            Picker("", selection: Binding(get: { key }, set: { action = .media($0) })) {
                ForEach(MediaKey.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .labelsHidden()
            .frame(width: 180)
        case .key(let combo):
            KeyRecorder(combo: Binding(get: { combo }, set: { action = .key($0) }))
                .frame(width: 140, height: 24)
            Text("sent to the frontmost app").font(.caption).foregroundStyle(.secondary)
        case .shortcut(let name):
            if shortcuts.isEmpty {
                TextField("Shortcut name", text: Binding(get: { name }, set: { action = .shortcut($0) }))
                    .frame(width: 200)
            } else {
                Picker("", selection: Binding(get: { name }, set: { action = .shortcut($0) })) {
                    ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                    if !shortcuts.contains(name) && !name.isEmpty { Text(name).tag(name) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
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
            Section("Recent detections") {
                if model.recentEvents.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentEvents.prefix(8)) { e in
                        Text(e.summary).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(e.isAccepted ? .primary : .secondary)
                    }
                }
            }
            Section("Privacy") {
                Text("Wave analyses the microphone signal in memory, on your Mac. Audio never leaves the Mac and is never saved, except recordings you start yourself in the debug window. The orange microphone dot in the menu bar is on whenever Wave is listening.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
