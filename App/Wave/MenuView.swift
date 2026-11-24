import SwiftUI
import WaveCore

/// The menu bar panel: status at a glance, what each gesture does, the two settings people actually change,
/// and the way to everything else.
struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                fixes
                cheatSheet
                if let last = model.lastGesture { lastGesture(last) }
                quickSettings
            }
            .padding(14)
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(statusColor.opacity(0.16))
                Image(systemName: model.health == .listening ? "dot.radiowaves.left.and.right" : model.menuSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: model.health == .listening)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wave").font(.system(size: 15, weight: .semibold))
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $model.prefs.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(model.prefs.enabled ? "Turn Wave off" : "Turn Wave on")
        }
        .padding(14)
    }

    private var statusLine: String {
        switch model.health {
        case .listening: return "Listening for gestures"
        case .off: return "Off"
        default: return model.statusText
        }
    }

    private var statusColor: Color {
        switch model.health {
        case .listening: return .green
        case .idle: return .secondary
        case .off: return .secondary
        case .problem: return .orange
        }
    }

    // MARK: Problems that stop Wave, each with its one-click fix

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
            FixCallout(text: "Wave needs Accessibility to press media keys and shortcuts.", button: "Grant…") {
                model.requestAccessibility()
            }
        }
    }

    // MARK: What each gesture does

    private var cheatSheet: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gestures").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Change…") { model.showSettings(tab: .gestures) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            VStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.title) { i, card in
                    if i > 0 { Divider().padding(.leading, 44) }
                    GestureCard(card: card, recent: isRecent(card))
                }
            }
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var cards: [GestureCardInfo] {
        let m = model.prefs.mapping
        var c: [GestureCardInfo] = [GestureCardInfo(title: "Push", symbol: GestureEvent.Kind.push.symbol, tint: GestureEvent.Kind.push.tint,
                              action: m.push.shortTitle, kind: .push)]
        if model.prefs.swipesEnabled {
            c.append(GestureCardInfo(title: "Swipe left", symbol: GestureEvent.Kind.swipeLeft.symbol, tint: GestureEvent.Kind.swipeLeft.tint,
                          action: m.swipeLeft.shortTitle, kind: .swipeLeft))
            c.append(GestureCardInfo(title: "Swipe right", symbol: GestureEvent.Kind.swipeRight.symbol, tint: GestureEvent.Kind.swipeRight.tint,
                          action: m.swipeRight.shortTitle, kind: .swipeRight))
        }
        if m.pull != .none {
            c.append(GestureCardInfo(title: "Pull", symbol: GestureEvent.Kind.pull.symbol, tint: GestureEvent.Kind.pull.tint,
                          action: m.pull.shortTitle, kind: .pull))
        }
        if model.prefs.grabEnabled {
            c.append(GestureCardInfo(title: "Fist", symbol: GestureEvent.Kind.grab.symbol, tint: GestureEvent.Kind.grab.tint,
                          action: m.grab.shortTitle, kind: .grab))
        }
        if model.prefs.dialEnabled, !model.prefs.dialTargets.isEmpty {
            c.append(GestureCardInfo(title: "Hover & hold", symbol: "dial.medium.fill", tint: .pink,
                          action: model.prefs.dialTargets.map(\.title).joined(separator: " · "), kind: nil))
        }
        return c
    }

    private func isRecent(_ card: GestureCardInfo) -> Bool {
        guard let last = model.lastGesture, let kind = card.kind else { return false }
        return last.kind == kind && Date().timeIntervalSince(last.at) < 4
    }

    private func lastGesture(_ last: (kind: GestureEvent.Kind, action: GestureAction, at: Date)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tertiary)
            Text("\(last.kind.title) → \(last.action.shortTitle)").lineLimit(1)
            Spacer()
            Text(last.at, style: .relative).foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    // MARK: The two settings people change

    private var quickSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sensitivity").font(.system(size: 13))
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
            Toggle(isOn: $model.prefs.onlyWhileMediaPlaying) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Only while media is playing").font(.system(size: 13))
                    Text(mediaCaption).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    /// Snaps the continuous sensitivity to the three presets for the segmented control.
    private var sensitivity: Binding<Double> {
        Binding(
            get: {
                let s = model.prefs.sensitivity
                return s < 0.35 ? 0.2 : (s < 0.65 ? 0.5 : 0.8)
            },
            set: { model.prefs.sensitivity = $0 })
    }

    private var mediaCaption: String {
        if !model.prefs.onlyWhileMediaPlaying { return "Wave listens all the time" }
        let apps = Set(model.mediaApps.map(MediaActivity.owningApp(of:))).sorted()
        return apps.isEmpty ? "Paused until something plays" : "Playing: " + apps.joined(separator: ", ")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Practice gestures…", symbol: "graduationcap") { model.showTutorial() }
            MenuRow(title: "Calibrate for this room…", symbol: "tuningfork") { model.showCalibration() }
            MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") { model.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
            Divider().padding(.vertical, 4).padding(.horizontal, 8)
            MenuRow(title: "Quit Wave", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(6)
    }
}

// MARK: - Pieces

/// One gesture and what it does, for the cheat sheet.
struct GestureCardInfo {
    let title: String
    let symbol: String
    let tint: Color
    let action: String
    let kind: GestureEvent.Kind?
}

private struct GestureCard: View {
    let card: GestureCardInfo
    let recent: Bool

    var body: some View {
        HStack(spacing: 10) {
            GestureBadge(symbol: card.symbol, tint: card.tint, size: 24)
            Text(card.title).font(.system(size: 13))
            Spacer(minLength: 8)
            Text(card.action)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(card.action == "Nothing" ? .tertiary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(recent ? card.tint.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: recent)
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

/// A native-looking menu row: highlights on hover.
private struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(hovering ? .white : .secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary) }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? .white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
