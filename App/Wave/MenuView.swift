import SwiftUI
import WaveCore

/// The menu bar panel: a live view of Wave listening, the last gesture, what your swipes do (one tap to
/// change), the gesture legend, quick controls, and shortcuts to everything else.
struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SonarHeader(model: model)
            VStack(alignment: .leading, spacing: 14) {
                fixes
                LastGestureCard(model: model)
                if model.prefs.swipesEnabled { swipeModes }
                legend
                quickControls
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)
            Divider()
            footer
        }
        .frame(width: 360)
    }

    // MARK: Problems, each with its fix

    @ViewBuilder private var fixes: some View {
        if model.micPermission != .authorized {
            FixCallout(text: "Wave needs the microphone to hear the tone's echo.",
                       button: model.micPermission == .notDetermined ? "Allow" : "Open Settings") {
                if model.micPermission == .notDetermined { model.requestMicrophone() } else { model.showOnboarding() }
            }
        }
        if model.speakersTooQuiet {
            FixCallout(text: model.speakerMuted ? "The MacBook speakers are muted." : "The MacBook speakers are too quiet for Wave.",
                       button: "Set to 50 %") { model.setSpeakers(to: 0.5) }
        }
        if !model.accessibilityTrusted {
            FixCallout(text: "Wave needs Accessibility to press keys for you.", button: "Grant…") { model.requestAccessibility() }
        }
    }

    // MARK: What swipes do, one tap to change

    private var swipeModes: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if model.prefs.smartMode, let place = model.smartPlace {
                    SectionTitle("Swipes in \(place)")
                    Text(model.smartPreset(for: .swipeLeft) == nil ? "your gestures" : "smart")
                        .font(.system(size: 9.5, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                } else {
                    SectionTitle("Swipes switch")
                }
                Spacer()
                Toggle("Smart", isOn: $model.prefs.smartMode)
                    .toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 10.5))
                    .help("Smart mode: swipes follow the app you're in — tabs in browsers, tracks in music apps, slides in Keynote")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(GesturePreset.all) { preset in
                    let on = model.currentSwipeMode?.id == preset.id
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { model.chooseSwipeMode(preset) }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: preset.symbol).font(.system(size: 14, weight: .semibold))
                            Text(preset.shortTitle).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(on ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(on ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.06)),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(preset.detail)
                }
            }
        }
    }

    // MARK: Gesture legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle("Your gestures")
                Spacer()
                Button("Change…") { model.showSettings(tab: .gestures) }.buttonStyle(.link).font(.system(size: 11.5))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(chips, id: \.title) { chip in
                    LegendChip(info: chip, recent: isRecent(chip))
                }
            }
        }
    }

    private var chips: [GestureCardInfo] {
        let m = model.prefs.mapping
        var c = [info(.push, m.push)]
        if model.prefs.swipesEnabled {
            c += [info(.swipeLeft, model.effectiveAction(for: .swipeLeft)), info(.swipeRight, model.effectiveAction(for: .swipeRight))]
        }
        if model.prefs.doublePushScreenshot {
            c.append(GestureCardInfo(title: "Push twice", symbol: "camera.viewfinder", tint: .blue, action: "Screenshot", kind: nil))
        }
        if m.pull != .none { c.append(info(.pull, m.pull)) }
        if model.prefs.grabEnabled { c.append(info(.grab, m.grab)) }
        if model.prefs.dialEnabled, !model.prefs.dialTargets.isEmpty {
            c.append(GestureCardInfo(title: "Hold up", symbol: "dial.medium.fill", tint: .pink,
                                     action: model.prefs.dialTargets.count > 1 ? "Volume, brightness" : model.prefs.dialTargets[0].title,
                                     kind: nil))
        }
        return c
    }

    private func info(_ kind: GestureEvent.Kind, _ action: GestureAction) -> GestureCardInfo {
        GestureCardInfo(title: kind.title, symbol: kind.symbol, tint: kind.tint, action: action.shortTitle, kind: kind)
    }

    private func isRecent(_ chip: GestureCardInfo) -> Bool {
        guard let last = model.lastGesture, let kind = chip.kind else { return false }
        return last.kind == kind && Date().timeIntervalSince(last.at) < 3
    }

    // MARK: Quick controls

    private var quickControls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Sensitivity").font(.system(size: 12.5))
                Spacer()
                Picker("Sensitivity", selection: sensitivity) {
                    Text("Strict").tag(0.2)
                    Text("Normal").tag(0.5)
                    Text("Sensitive").tag(0.8)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }
            HStack(spacing: 8) {
                if let until = model.snoozedUntil {
                    PillButton(title: "Resume (snoozed till \(until.formatted(date: .omitted, time: .shortened)))",
                               symbol: "moon.zzz.fill", tint: .indigo, active: true) { model.snooze(for: nil) }
                } else {
                    PillButton(title: "Snooze 1 hour", symbol: "moon.zzz", tint: .indigo, active: false) { model.snooze(for: 3600) }
                }
                PillButton(title: model.prefs.onlyWhileMediaPlaying ? "Only with media" : "Always listening",
                           symbol: model.prefs.onlyWhileMediaPlaying ? "music.note" : "ear", tint: .teal,
                           active: model.prefs.onlyWhileMediaPlaying) {
                    model.prefs.onlyWhileMediaPlaying.toggle()
                }
                .help("Only listen while something is playing (and a few minutes after)")
            }
        }
    }

    private var sensitivity: Binding<Double> {
        Binding(
            get: {
                let s = model.prefs.sensitivity
                return s < 0.35 ? 0.2 : (s < 0.65 ? 0.5 : 0.8)
            },
            set: { model.prefs.sensitivity = $0 })
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                FooterTile(title: "Practice", symbol: "graduationcap.fill", tint: .green) { model.showTutorial() }
                FooterTile(title: "Calibrate", symbol: "tuningfork", tint: .purple) { model.showCalibration() }
                FooterTile(title: "Settings", symbol: "gearshape.fill", tint: .gray) { model.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            HStack {
                Text(model.gesturesToday == 0 ? "No gestures yet today"
                     : "\(model.gesturesToday) gesture\(model.gesturesToday == 1 ? "" : "s") today")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Wave") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
    }
}

// MARK: - Header

/// Wave's status with a live sonar: rings ripple out while it's listening.
private struct SonarHeader: View {
    @Bindable var model: AppModel

    private var listening: Bool { model.health == .listening }
    private var color: Color {
        switch model.health {
        case .listening: return .green
        case .problem: return .orange
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                if listening {
                    TimelineView(.animation) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        ZStack {
                            ForEach(0..<3) { i in
                                let p = (t / 1.8 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                                Circle().stroke(color.opacity(0.55 * (1 - p)), lineWidth: 1.5)
                                    .frame(width: 22 + 30 * p, height: 22 + 30 * p)
                            }
                        }
                    }
                }
                Circle().fill(color.gradient).frame(width: 30, height: 30)
                Image(systemName: listening ? "hand.wave.fill" : model.menuSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wave").font(.system(size: 16, weight: .bold))
                Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $model.prefs.enabled).toggleStyle(.switch).labelsHidden()
                .help(model.prefs.enabled ? "Turn Wave off" : "Turn Wave on")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [color.opacity(listening ? 0.16 : 0.06), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var statusLine: String {
        switch model.health {
        case .listening: return "Listening — wave at your screen"
        case .off: return "Off"
        default: return model.statusText
        }
    }
}

// MARK: - Last gesture

/// The last gesture and what it did; glows in the gesture's colour for a moment after it happens.
private struct LastGestureCard: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let fresh = model.lastGesture.map { Date().timeIntervalSince($0.at) < 2.5 } ?? false
            HStack(spacing: 10) {
                if let last = model.lastGesture {
                    GestureBadge(symbol: last.action.symbol, tint: last.kind.tint, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(last.action.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(last.kind.title) · \(last.at.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if fresh { Image(systemName: "checkmark.circle.fill").foregroundStyle(last.kind.tint) }
                } else {
                    GestureBadge(symbol: "sparkles", tint: .gray, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Try a gesture").font(.system(size: 13, weight: .semibold))
                        Text("Push toward the screen, or swipe across it").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(10)
            .background((fresh ? model.lastGesture?.kind.tint ?? .clear : .clear).opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.3), value: fresh)
        }
    }
}

// MARK: - Pieces

/// One gesture and what it does, for the legend.
struct GestureCardInfo {
    let title: String
    let symbol: String
    let tint: Color
    let action: String
    let kind: GestureEvent.Kind?
}

private struct LegendChip: View {
    let info: GestureCardInfo
    let recent: Bool

    var body: some View {
        HStack(spacing: 8) {
            GestureBadge(symbol: info.symbol, tint: info.tint, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(info.title).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                Text(info.action).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                    .foregroundStyle(info.action == "Nothing" ? .tertiary : .primary)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(recent ? info.tint.opacity(0.2) : Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: recent)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

private struct PillButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(active ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(active ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.06)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct FooterTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                GestureBadge(symbol: symbol, tint: tint, size: 28)
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(hovering ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A problem with a one-click fix.
private struct FixCallout: View {
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action).controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension GestureAction {
    /// Short label for tight spaces ("Play/Pause", "Next desktop", "⌘W").
    var shortTitle: String {
        switch self {
        case .none: return "Nothing"
        case .key(let combo): return combo.display
        case .shortcut(let name): return name.isEmpty ? "Shortcut" : name
        default: return title
        }
    }
}
