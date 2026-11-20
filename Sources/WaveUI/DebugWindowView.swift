import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WaveCore

/// M1 debug window: controls, live spectrogram, feature traces and the gesture event log.
public struct DebugWindowView: View {
    @Bindable var model: DebugModel

    public init(model: DebugModel) { self.model = model }

    public var body: some View {
        // Each part is its own view so SwiftUI's observation tracking redraws only what changed
        // (the plots and status line update ~30×/s; the controls and event table rarely).
        VStack(alignment: .leading, spacing: 10) {
            DebugControls(model: model)
            DebugStatusLine(model: model)
            SpectrogramView(model: model)
                .frame(minHeight: 200)
            FeatureTraceView(model: model)
                .frame(height: 190)
            DebugEventLog(model: model)
        }
        .padding(12)
        .frame(minWidth: 960, minHeight: 760)
    }

}

struct DebugControls: View {
    @Bindable var model: DebugModel

    var body: some View {
        HStack(spacing: 16) {
            if model.status.isActive {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button { model.start() } label: { Label("Start", systemImage: "play.fill") }
                    .keyboardShortcut(.defaultAction)
            }
            Picker("Pilot", selection: $model.pilotHz) {
                Text("18.75 kHz").tag(18_750.0)
                Text("19.0 kHz").tag(19_000.0)
                Text("19.25 kHz").tag(19_250.0)
            }
            .frame(width: 170)
            labeledSlider("Level", value: $model.amplitudeDBFS, range: -20 ... -2, text: String(format: "%.0f dBFS", model.amplitudeDBFS))
            labeledSlider("Sensitivity", value: $model.sensitivity, range: 0...1, text: String(format: "%.2f", model.sensitivity))
            Spacer()
            TextField("label", text: $model.recordLabel)
                .frame(width: 80)
                .help("Optional label stored with the recording (e.g. push, none)")
            Button { model.toggleRecording() } label: {
                Label(model.recordingURL == nil ? "Record" : "Stop rec", systemImage: model.recordingURL == nil ? "record.circle" : "stop.circle")
                    .foregroundStyle(model.recordingURL == nil ? Color.primary : Color.red)
            }
            .disabled(!(model.status == .running || model.recordingURL != nil))
            .help("Debug only: saves raw mic audio (.caf + .json) for replay")
            Button("Replay…") { chooseReplay(model) }
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Slider(value: value, in: range).frame(width: 110)
            Text(text).monospacedDigit().frame(width: 62, alignment: .leading).foregroundStyle(.secondary)
        }
    }

}

struct DebugStatusLine: View {
    let model: DebugModel

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(model.replayingFile.map { "\(model.status.text) — \($0)" } ?? model.status.text).fontWeight(.medium)
            }
            if let a = model.currentAmplitude {
                Text(String(format: "pilot %.1f dBFS", a) + (model.speakerGainDB.map { String(format: " · speakers %.1f dB", $0) } ?? ""))
            }
            if let f = model.latest {
                Text(String(format: "▲ %+.1f  ▼ %+.1f  ref %+.1f dB  v %+.2f m/s", f.towardDB, f.awayDB, f.referenceDB, f.velocity))
                    .monospacedDigit()
            }
            if let idle = model.inputIdle {
                Text(idle < 0.8 ? "input: gated" : String(format: "input idle %.0f s", idle))
                    .foregroundStyle(idle < 0.8 ? .orange : .secondary)
            }
            if model.droppedFrames > 0 { Text("dropped \(model.droppedFrames)").foregroundStyle(.red) }
            Spacer()
            if let saved = model.lastSavedRecording {
                Button("Saved \(saved.lastPathComponent)") { model.revealRecordings() }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
    }

    private var statusColor: Color {
        switch model.status {
        case .running: return .green
        case .replaying: return .blue
        case .paused: return .orange
        case .failed: return .red
        case .stopped: return .gray
        }
    }

}

struct DebugEventLog: View {
    @Bindable var model: DebugModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Events").font(.headline)
                Text("\(model.acceptedCount) gesture\(model.acceptedCount == 1 ? "" : "s") · \(model.events.count - model.acceptedCount) rejected")
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Show rejected", isOn: $model.showRejected)
                Button("Clear") { model.clearEvents() }
            }
            Table(model.showRejected ? model.events : model.events.filter(\.isAccepted)) {
                TableColumn("Time") { e in Text(String(format: "%.2f s", e.end)).monospacedDigit() }
                    .width(70)
                TableColumn("Gesture") { e in Text(e.kind.rawValue.capitalized) }
                    .width(60)
                TableColumn("Result") { e in
                    Text(e.isAccepted ? "✓ accepted" : "✗ \(e.outcome.rawValue)")
                        .foregroundStyle(e.isAccepted ? Color.green : Color.red)
                }
                .width(min: 120, ideal: 200)
                TableColumn("Confidence") { e in
                    HStack(spacing: 6) {
                        ProgressView(value: e.confidence).frame(width: 60)
                        Text(String(format: "%.2f", e.confidence)).monospacedDigit()
                    }
                }
                .width(110)
                TableColumn("▲ toward") { e in Text(String(format: "%+.1f dB", e.towardPeakDB)).monospacedDigit() }
                    .width(75)
                TableColumn("▼ away") { e in Text(String(format: "%+.1f dB", e.awayPeakDB)).monospacedDigit() }
                    .width(75)
                TableColumn("Duration") { e in Text(String(format: "%.2f s", e.duration)).monospacedDigit() }
                    .width(70)
                TableColumn("Velocity") { e in
                    Text(String(format: "%+.2f / %+.2f m/s", e.towardPeakVelocity, e.awayPeakVelocity)).monospacedDigit()
                }
                .width(min: 110, ideal: 130)
            }
            .frame(minHeight: 150)
        }
    }
}

@MainActor
private func chooseReplay(_ model: DebugModel) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "caf") ?? .audio]
    panel.directoryURL = RecordingWriter.defaultDirectory
    panel.message = "Choose a Wave debug recording to replay"
    if panel.runModal() == .OK, let url = panel.url { model.replay(url) }
}
