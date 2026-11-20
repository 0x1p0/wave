import SwiftUI
import WaveCore

/// The menu bar panel: on/off, status, sensitivity, quick fixes and links.
struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "hand.wave.fill").font(.title2).foregroundStyle(.tint)
                Text("Wave").font(.headline)
                Spacer()
                Toggle("", isOn: $model.prefs.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Turn Wave on or off")
            }

            HStack(spacing: 8) {
                Circle().fill(healthColor).frame(width: 8, height: 8)
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            fixes

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text(sensitivityLabel).foregroundStyle(.secondary).font(.caption)
                }
                Slider(value: $model.prefs.sensitivity, in: 0...1)
            }

            Toggle("Only while media is playing", isOn: $model.prefs.onlyWhileMediaPlaying)

            if let last = model.lastGesture {
                HStack(spacing: 6) {
                    Image(systemName: last.action.symbol).foregroundStyle(.secondary)
                    Text("\(last.kind.title) → \(last.action.title)")
                    Spacer()
                    Text(last.at, style: .relative).foregroundStyle(.secondary).font(.caption)
                }
                .font(.callout)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                menuButton("Learn gestures…", "graduationcap") { model.showTutorial() }
                menuButton("Settings…", "gearshape") { model.showSettings() }
                menuButton("Calibrate…", "slider.horizontal.3") { model.showCalibration() }
                menuButton("Debug window…", "waveform") { model.showDebugWindow() }
                menuButton("Quit Wave", "power") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder private var fixes: some View {
        if model.micPermission != .authorized {
            fixRow("Microphone access is needed", button: model.micPermission == .notDetermined ? "Allow" : "Open Settings") {
                if model.micPermission == .notDetermined { model.requestMicrophone() } else { model.showOnboarding() }
            }
        }
        if model.speakersTooQuiet {
            fixRow(model.speakerMuted ? "MacBook speakers are muted" : "Speaker volume too low for Wave",
                   button: "Set to 50 %") { model.setSpeakers(to: 0.5) }
        }
        if !model.accessibilityTrusted {
            fixRow("Needs Accessibility to send media keys", button: "Grant…") { model.requestAccessibility() }
        }
    }

    private func fixRow(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action).controlSize(.small)
        }
    }

    private func menuButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
    }

    private var sensitivityLabel: String {
        switch model.prefs.sensitivity {
        case ..<0.3: return "strict"
        case ..<0.7: return "normal"
        default: return "sensitive"
        }
    }

    private var healthColor: Color {
        switch model.health {
        case .listening: return .green
        case .idle: return .gray
        case .off: return .secondary
        case .problem: return .orange
        }
    }
}
