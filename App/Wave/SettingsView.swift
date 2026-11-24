import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WaveCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 210)
            Divider()
            Group {
                switch model.settingsTab {
                case .gestures: GesturesPage(model: model)
                case .apps: AppsPage(model: model)
                case .hover: HoverPage(model: model)
                case .general: SettingsPage("General", "How Wave runs on your Mac") { GeneralSettings(model: model) }
                case .sound: SettingsPage("Sound", "The tone Wave plays and the speakers it uses") { SoundSettings(model: model) }
                case .calibration: SettingsPage("Calibration", "Tune detection to your room and your hand") { CalibrationSettings(model: model) }
                case .advanced: SettingsPage("Advanced", "Logs, debugging and privacy") { AdvancedSettings(model: model) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 620)
    }
}

/// Sidebar like System Settings: Wave's status on top, then the pages.
struct SettingsSidebar: View {
    @Bindable var model: AppModel

    private let items: [(AppModel.SettingsTab, String, String, Color)] = [
        (.gestures, "Gestures", "hand.wave.fill", .blue),
        (.apps, "Apps (smart mode)", "square.grid.2x2.fill", .teal),
        (.hover, "Volume & brightness", "dial.medium.fill", .pink),
        (.general, "General", "gearshape.fill", .gray),
        (.sound, "Sound", "speaker.wave.2.fill", .orange),
        (.calibration, "Calibration", "tuningfork", .purple),
        (.advanced, "Advanced", "wrench.and.screwdriver.fill", .gray),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                GestureBadge(symbol: "hand.wave.fill", tint: .blue, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Wave").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(model.health == .listening ? Color.green : .secondary).frame(width: 7, height: 7)
                        Text(model.health == .listening ? "Listening" : (model.health == .off ? "Off" : "Paused"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Toggle("", isOn: $model.prefs.enabled).toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 14)
            ForEach(items, id: \.0) { item in
                let selected = model.settingsTab == item.0
                Button { model.settingsTab = item.0 } label: {
                    HStack(spacing: 9) {
                        GestureBadge(symbol: item.2, tint: item.3, size: 22)
                        Text(item.1).font(.system(size: 13))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { model.showTutorial() } label: {
                Label("Practice gestures", systemImage: "graduationcap.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(10)
        }
        .padding(.horizontal, 8)
        .background(.background.secondary)
    }
}

/// A page title and subtitle above a page's content.
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grouped-form page with a header.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title, subtitle: subtitle).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 4)
            content
        }
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

struct GesturesPage: View {
    @Bindable var model: AppModel
    @State private var shortcuts: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Gestures", subtitle: "Wave sees your hand with sound from the speakers. Pick what each move does.")
                LiveStrip(model: model)
                presets
                section("Your gestures") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        GestureCard(kind: .push, action: $model.prefs.mapping.push, shortcuts: shortcuts) { model.perform(.push) }
                        if model.prefs.swipesEnabled {
                            GestureCard(kind: .swipeLeft, action: $model.prefs.mapping.swipeLeft, shortcuts: shortcuts) { model.perform(.swipeLeft) }
                            GestureCard(kind: .swipeRight, action: $model.prefs.mapping.swipeRight, shortcuts: shortcuts) { model.perform(.swipeRight) }
                        }
                        GestureCard(kind: .pull, action: $model.prefs.mapping.pull, shortcuts: shortcuts) { model.perform(.pull) }
                        if model.prefs.grabEnabled {
                            GestureCard(kind: .grab, action: $model.prefs.mapping.grab, shortcuts: shortcuts) { model.perform(.grab) }
                        }
                    }
                }
                section("More gestures") {
                    VStack(spacing: 0) {
                        ToggleRow(title: "Swipe left and right", detail: "Plays a separate tone on each speaker so Wave can tell left from right.",
                                  symbol: "hand.point.left.fill", tint: .teal, isOn: $model.prefs.swipesEnabled)
                        Divider().padding(.leading, 46)
                        ToggleRow(title: "Fist (experimental)",
                                  detail: "Hold your hand up until ✋ appears, then close it quickly. Misses some fists; taps and typing can't set it off.",
                                  symbol: "hand.raised.fingers.spread.fill", tint: .orange, isOn: $model.prefs.grabEnabled)
                    }
                    .padding(.vertical, 4)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if usesDesktops {
                    Label("Desktop switching uses ⌃← and ⌃→. Keep them on in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.accessibilityTrusted {
                    PermissionRow(title: "Accessibility", detail: "Needed to press media keys and shortcuts for you",
                                  granted: false, action: "Open Settings") { model.requestAccessibility() }
                        .padding(12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(28)
        }
        .task { shortcuts = await ShortcutsRunner.list() }
    }

    private var usesDesktops: Bool {
        let m = model.prefs.mapping
        return [m.push, m.swipeLeft, m.swipeRight, m.pull].contains { $0 == .system(.nextDesktop) || $0 == .system(.previousDesktop) }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private var presets: some View {
        section(model.prefs.smartMode ? "Swipes in every other app (smart mode handles browsers, music, slides)" : "What swipes do") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(GesturePreset.all) { preset in
                    let on = preset.matches(model.prefs.mapping)
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            preset.apply(to: &model.prefs.mapping)
                            if !model.prefs.swipesEnabled { model.prefs.swipesEnabled = true }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: preset.symbol)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(on ? .white : .accentColor)
                                .frame(width: 30, height: 30)
                                .background(on ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.accentColor.opacity(0.12)),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.title).font(.system(size: 12.5, weight: .semibold))
                                Text(on ? "In use" : "Use this").font(.system(size: 11)).foregroundStyle(on ? Color.accentColor : .secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(9)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(preset.detail)
                }
            }
        }
    }
}

/// What Wave just saw, live: flashes when a gesture is recognised, so you can test gestures right here.
struct LiveStrip: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill((model.health == .listening ? Color.green : .secondary).opacity(0.18))
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(model.health == .listening ? .green : .secondary)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: model.health == .listening)
            }
            .frame(width: 34, height: 34)
            if let last = model.lastGesture {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let fresh = Date().timeIntervalSince(last.at) < 2
                    HStack(spacing: 8) {
                        GestureBadge(symbol: last.kind.symbol, tint: last.kind.tint, size: 24)
                        Text(last.kind.title).font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(last.action.title).font(.system(size: 13))
                        Spacer()
                        Text(last.at, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(fresh ? last.kind.tint.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .animation(.easeOut(duration: 0.3), value: fresh)
                }
                .id(last.at)
            } else {
                Text(model.health == .listening ? "Try a gesture: it shows up here." : "Wave isn't listening right now — \(model.statusText).")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A gesture: a little animation of the move, how to do it, what it does, and a button to try the action.
struct GestureCard: View {
    let kind: GestureEvent.Kind
    @Binding var action: GestureAction
    let shortcuts: [String]
    let test: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GestureIllustration(kind: kind)
                .frame(height: 92)
                .frame(maxWidth: .infinity)
                .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.system(size: 14, weight: .semibold))
                    Text(kind.howTo).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: test) { Label("Try", systemImage: "play.fill").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .disabled(action == .none)
                    .help("Runs the action now, as if you'd made the gesture")
            }
            ActionMenu(action: $action, shortcuts: shortcuts)
            if case .key(let combo) = action {
                HStack {
                    Text("Keys").font(.caption).foregroundStyle(.secondary)
                    KeyRecorder(combo: Binding(get: { combo }, set: { action = .key($0) })).frame(height: 24)
                }
            }
            if case .shortcut(let name) = action, shortcuts.isEmpty {
                TextField("Shortcut name", text: Binding(get: { name }, set: { action = .shortcut($0) }))
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Front view of the laptop and a hand doing the gesture, on a loop.
struct GestureIllustration: View {
    let kind: GestureEvent.Kind?
    var hover = false

    var body: some View {
        TimelineView(.animation) { tl in
            let u = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let p = pose(u)
            ZStack {
                // Laptop screen seen from the front.
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.5), lineWidth: 2)
                    .frame(width: 92, height: 58)
                    .offset(y: -6)
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 112, height: 5).offset(y: 26)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(tint.gradient)
                    .scaleEffect(x: p.scale, y: p.scale * p.squash)
                    .offset(x: p.x, y: -2)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
                if p.ring > 0 {
                    Circle().stroke(tint.opacity(0.6), lineWidth: 2)
                        .frame(width: 44 + 20 * p.ring, height: 44 + 20 * p.ring)
                        .opacity(1 - p.ring)
                        .offset(x: p.x, y: -2)
                }
            }
        }
    }

    private var tint: Color { kind?.tint ?? .pink }

    private struct Pose { var x: CGFloat = 0; var scale: CGFloat = 1; var squash: CGFloat = 1; var ring: Double = 0 }

    private func bump(_ u: Double, _ a: Double, _ b: Double) -> Double {
        guard u > a && u < b else { return 0 }
        return 0.5 * (1 - cos(2 * Double.pi * (u - a) / (b - a)))
    }

    private func pose(_ u: Double) -> Pose {
        var p = Pose()
        if hover {
            p.scale = 0.8 + 0.35 * min(1, u / 0.25)
            if u > 0.3 && u < 0.6 { p.ring = (u - 0.3) / 0.3 }
            p.scale += 0.18 * bump(u, 0.65, 0.85)
            return p
        }
        switch kind {
        case .push: p.scale = 0.8 + 0.6 * bump(u, 0.15, 0.6)
        case .pull: p.scale = 1.3 - 0.55 * bump(u, 0.15, 0.6)
        case .swipeLeft: p.x = CGFloat(60 - 120 * min(1, max(0, (u - 0.15) / 0.45))); p.scale = 1
        case .swipeRight: p.x = CGFloat(-60 + 120 * min(1, max(0, (u - 0.15) / 0.45))); p.scale = 1
        case .grab:
            p.scale = 1.1
            p.squash = u > 0.45 && u < 0.85 ? 0.55 : 1
        case .none: break
        }
        return p
    }
}

/// A switch with an icon, a title and a line of explanation.
struct ToggleRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            GestureBadge(symbol: symbol, tint: tint, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Apps (smart mode)

struct AppsPage: View {
    @Bindable var model: AppModel
    @State private var added: [String] = []

    private var apps: [(id: String, name: String, url: URL)] {
        let ids = Set(SmartModes.builtIn.keys).union(model.prefs.appModes.keys).union(added)
        return ids.compactMap { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return (id, name, url)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Apps", subtitle: "Swipes do the right thing in each app: tabs in your browser, tracks in your music app, slides in Keynote.")
                VStack(spacing: 0) {
                    ToggleRow(title: "Smart mode", detail: "Swipes follow the app you're in. Push always does the same thing everywhere.",
                              symbol: "sparkles", tint: .teal, isOn: $model.prefs.smartMode)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if model.prefs.smartMode {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Swipes in each app").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(apps.enumerated()), id: \.element.id) { i, app in
                                if i > 0 { Divider().padding(.leading, 52) }
                                HStack(spacing: 12) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                        .resizable().frame(width: 28, height: 28)
                                    Text(app.name).font(.system(size: 13))
                                    if model.frontApp?.id == app.id {
                                        Text("in front").font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                                    }
                                    Spacer()
                                    Picker("", selection: modeBinding(app.id)) {
                                        Text("My gestures").tag("default")
                                        Divider()
                                        ForEach(GesturePreset.all) { Label($0.title, systemImage: $0.symbol).tag($0.id) }
                                    }
                                    .labelsHidden()
                                    .frame(width: 180)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                            }
                            Divider()
                            HStack(spacing: 12) {
                                GestureBadge(symbol: "macwindow", tint: .gray, size: 28)
                                Text("Every other app").font(.system(size: 13))
                                Spacer()
                                Text(model.prefs.mapping.swipeLeft.shortTitle + " / " + model.prefs.mapping.swipeRight.shortTitle)
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Button("Change…") { model.settingsTab = .gestures }.buttonStyle(.link).font(.system(size: 12))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button { addApp() } label: { Label("Add an app…", systemImage: "plus") }
                        Text("Websites in your browser").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.top, 8)
                        VStack(spacing: 0) {
                            ForEach(SmartModes.sites, id: \.id) { site in
                                HStack(spacing: 12) {
                                    GestureBadge(symbol: "play.rectangle.fill", tint: .red, size: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(site.name).font(.system(size: 13))
                                        Text("Recognised from the browser's window title").font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    if model.frontSite?.id == site.id {
                                        Text("watching now").font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                                    }
                                    Spacer()
                                    Picker("", selection: Binding(
                                        get: { model.prefs.siteModes[site.id] ?? site.mode },
                                        set: { model.prefs.siteModes[site.id] = $0 })) {
                                        Text("Like the browser").tag("default")
                                        Divider()
                                        ForEach(GesturePreset.all) { Label($0.title, systemImage: $0.symbol).tag($0.id) }
                                    }
                                    .labelsHidden()
                                    .frame(width: 180)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .padding(28)
        }
    }

    private func modeBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { model.prefs.appModes[id] ?? SmartModes.builtIn[id] ?? "default" },
            set: { model.prefs.appModes[id] = $0 })
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        if model.prefs.appModes[id] == nil && SmartModes.builtIn[id] == nil { model.prefs.appModes[id] = "default" }
        added.append(id)
    }
}

// MARK: - Volume & brightness

struct HoverPage: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Volume & brightness", subtitle: "Two ways to change them without touching your Mac.")
                HStack(alignment: .top, spacing: 12) {
                    GestureBadge(symbol: "speaker.wave.2.fill", tint: .teal, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recommended: swipe for volume").font(.system(size: 14, weight: .semibold))
                        Text("Pick Volume (or Brightness) in the menu's swipe modes — swipe right louder, left quieter — then switch back. Swipes are Wave's most reliable gesture.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Use Volume swipes here") { if let p = GesturePreset.named("volume") { model.chooseSwipeMode(p) } }
                            Button("Brightness swipes") { if let p = GesturePreset.named("brightness") { model.chooseSwipeMode(p) } }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(14)
                .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Or: hover (experimental)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Text("Hold your hand up to the screen, then push or pull. It's off by default: to the sonar, a hand held still and a hand that just paused look the same, so it can open when you don't mean it and miss when you do.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 18) {
                    GestureIllustration(kind: nil, hover: true)
                        .frame(width: 180, height: 130)
                        .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 12) {
                        step(1, "Push your open hand toward the screen and keep it there, about 20 cm away.",
                             "Raising it from below doesn't count: Wave needs to see it come toward the screen.")
                        step(2, "Hold it still. A ring fills up, then ✋ appears.", "Small wobbles are fine; it just waits a moment longer. Not right after a push or swipe.")
                        step(3, "Quick push = up, quick pull = down.",
                             "Brisk, like play/pause. Gentle presses are too slow for the sonar to see.")
                        step(4, "Swipe to switch between volume and brightness. It closes by itself 4 s after your last change.", nil)
                    }
                }
                VStack(spacing: 0) {
                    ToggleRow(title: "Volume and brightness by hovering", detail: "Off: pushes and pulls always do their normal actions.",
                              symbol: "dial.medium.fill", tint: .pink, isOn: $model.prefs.dialEnabled)
                    if model.prefs.dialEnabled {
                        Divider().padding(.leading, 46)
                        HStack {
                            Text("Controls").font(.system(size: 13))
                            Spacer()
                            Picker("", selection: $model.prefs.dialTargets) {
                                Text("Volume, then brightness").tag([DialTarget.volume, .brightness])
                                Text("Brightness, then volume").tag([DialTarget.brightness, .volume])
                                Text("Volume only").tag([DialTarget.volume])
                                Text("Brightness only").tag([DialTarget.brightness])
                            }
                            .labelsHidden().frame(width: 220)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        Divider().padding(.leading, 12)
                        HStack {
                            Text("Each push or pull changes it by").font(.system(size: 13))
                            Spacer()
                            Picker("", selection: $model.prefs.dialStep) {
                                Text("5 %").tag(5.0)
                                Text("10 %").tag(10.0)
                                Text("20 %").tag(20.0)
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                if !BrightnessController.isAvailable {
                    Label("Smooth brightness isn't available on this Mac; brightness changes in key-sized steps.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { model.showTutorial() } label: { Label("Practice it in the tutorial", systemImage: "graduationcap") }
            }
            .padding(28)
        }
    }

    private func step(_ n: Int, _ text: String, _ note: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Color.pink.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
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

/// Every action in one menu, grouped.
struct ActionMenu: View {
    @Binding var action: GestureAction
    let shortcuts: [String]

    private static let groups: [(String, [SystemAction])] = [
        ("Windows and desktops", [.nextDesktop, .previousDesktop, .missionControl, .appWindows, .showDesktop, .minimizeWindow,
                                  .closeWindow, .hideApp, .fullScreen, .switchApp]),
        ("Browser and documents", [.nextTab, .previousTab, .back, .forward, .reopenTab, .pageDown, .pageUp, .zoomIn, .zoomOut]),
        ("Presenting", [.nextSlide, .previousSlide]),
        ("Volume and brightness", [.volumeUp, .volumeDown, .brightnessUp, .brightnessDown]),
        ("System", [.spotlight, .screenshot, .lockScreen]),
    ]

    var body: some View {
        Picker("", selection: $action) {
            Label("Nothing", systemImage: "circle.slash").tag(GestureAction.none)
            Section("Media") {
                ForEach(MediaKey.allCases) { Label($0.title, systemImage: $0.symbol).tag(GestureAction.media($0)) }
            }
            ForEach(Self.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { Label($0.title, systemImage: $0.symbol).tag(GestureAction.system($0)) }
                }
            }
            Section("Your own") {
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
