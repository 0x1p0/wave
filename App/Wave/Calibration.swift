import SwiftUI
import WaveCore

/// Guided calibration: measure the still room, collect 5 examples of each gesture, compute thresholds.
@MainActor
@Observable
final class CalibrationSession {
    enum Step: Equatable { case intro, quiet, gesture(GestureEvent.Kind), review, saved }

    let model: AppModel
    let layout: PilotLayout
    let target = 5
    private(set) var step: Step = .intro
    private(set) var quietProgress = 0.0
    private(set) var counts: [GestureEvent.Kind: Int] = [:]
    private(set) var message = ""
    private(set) var profile: CalibrationProfile?
    private(set) var noiseDB: Float?

    @ObservationIgnored private var quietFrames: [PipelineFrame] = []
    @ObservationIgnored private var quietStart: Double?
    @ObservationIgnored private var collected: [GestureEvent.Kind: [GestureEvent]] = [:]
    @ObservationIgnored private var lastAccepted = -Double.infinity
    @ObservationIgnored private var active = false
    @ObservationIgnored private var settings: EngineSettings
    @ObservationIgnored private let includeGrab: Bool
    /// Grab step: the hand is raised and still ("✋ ready").
    private(set) var handReady = false

    static let quietSeconds = 4.0

    var kinds: [GestureEvent.Kind] {
        (layout.isStereo ? [.push, .swipeLeft, .swipeRight] : [.push]) + (includeGrab ? [.grab] : [])
    }

    init(model: AppModel) {
        self.model = model
        layout = model.prefs.pilotLayout
        settings = model.prefs.engineSettings
        includeGrab = model.prefs.grabEnabled
    }

    func begin() {
        guard !model.speakersTooQuiet else {
            message = "The MacBook speakers are muted or too quiet. Set them to 50 % first."
            return
        }
        active = true
        step = .quiet
        message = ""
        quietFrames = []
        quietStart = nil
        collected = [:]
        counts = [:]
        // No detection while measuring the still room.
        settings.detector = DetectorConfig()
        settings.detector.minPeakDB = 99
        settings.fusion = Calibrator.collectionFusion()
        model.beginExclusive(.calibrating, settings: settings) { [weak self] out in
            self?.ingest(out)
        }
    }

    private func ingest(_ out: EngineOutput) {
        let frames = out.frames, events = out.events
        for c in out.controls {
            switch c {
            case .ready: handReady = true
            case .ended: handReady = false
            default: break
            }
        }
        switch step {
        case .quiet:
            for f in frames {
                if quietStart == nil { quietStart = f.time }
                if f.time - (quietStart ?? f.time) > 0.8 { quietFrames.append(f) }  // after baseline warm-up
            }
            quietProgress = min(1, Double(quietFrames.count) / (Self.quietSeconds * 48_000 / 512))
            if quietProgress >= 1 {
                let noise = Calibrator.noiseLevel(quietFrames)
                noiseDB = noise
                settings.detector = Calibrator.collectionDetector(noiseDB: noise)
                settings.interaction = Calibrator.collectionInteraction(microNoiseDB: Calibrator.microLevel(quietFrames))
                model.updateExclusive(settings: settings)
                step = .gesture(kinds[0])
            }
        case .gesture(let kind):
            for e in events {
                if e.outcome == .oneSided {
                    message = "Only one speaker noticed that one. Try a little closer to the middle."
                    continue
                }
                // Grab step counts grabs only; the other steps count anything push/swipe-shaped.
                guard e.isAccepted, (e.kind == .grab) == (kind == .grab), e.end - lastAccepted > 0.5 else { continue }
                lastAccepted = e.end
                collected[kind, default: []].append(e)
                let n = collected[kind]!.count
                counts[kind] = n
                message = n < target ? "Got it — \(n) of \(target)." : "Done."
                if n >= target { advance(after: kind) }
            }
        default:
            break
        }
    }

    func skip() {
        if case .gesture(let kind) = step { advance(after: kind) }
    }

    private func advance(after kind: GestureEvent.Kind) {
        if let i = kinds.firstIndex(of: kind), i + 1 < kinds.count {
            step = .gesture(kinds[i + 1])
            message = ""
        } else {
            finish()
        }
    }

    private func finish() {
        profile = Calibrator.makeProfile(
            layout: layout, quiet: quietFrames, pushes: collected[.push] ?? [],
            swipesLeft: collected[.swipeLeft] ?? [], swipesRight: collected[.swipeRight] ?? [],
            grabs: collected[.grab] ?? [])
        step = .review
        stopEngine()
    }

    func save() {
        guard let profile else { return }
        model.prefs.calibration = profile
        step = .saved
    }

    func cancel() { stopEngine() }

    private func stopEngine() {
        guard active else { return }
        active = false
        model.endExclusive()
    }
}

struct CalibrationView: View {
    let session: CalibrationSession
    @Environment(\.dismissWindow) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
    }

    @ViewBuilder private var content: some View {
        switch session.step {
        case .intro:
            Text("Calibrate Wave").font(.title2.bold())
            Text("Sit the way you usually do. Wave will measure the room for a few seconds (keep still and quiet), then ask you to do each gesture \(session.target) times.")
            gestureHelp
            if !session.message.isEmpty { Label(session.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Button("Start") { session.begin() }.keyboardShortcut(.defaultAction)
        case .quiet:
            Text("Keep still…").font(.title2.bold())
            Text("Hands in your lap, away from the laptop. Measuring the room.")
            ProgressView(value: session.quietProgress)
        case .gesture(let kind):
            Text(title(for: kind)).font(.title2.bold())
            Text(instructions(for: kind))
            HStack(spacing: 10) {
                ForEach(0..<session.target, id: \.self) { i in
                    Image(systemName: i < (session.counts[kind] ?? 0) ? "checkmark.circle.fill" : "circle")
                        .font(.title)
                        .foregroundStyle(i < (session.counts[kind] ?? 0) ? .green : .secondary)
                }
            }
            if !session.message.isEmpty { Text(session.message).foregroundStyle(.secondary) }
            if let n = session.noiseDB { Text(String(format: "Room noise: %.1f dB", n)).font(.caption).foregroundStyle(.secondary) }
            Button("Skip this gesture") { session.skip() }
        case .review:
            Text("Calibration result").font(.title2.bold())
            if let p = session.profile {
                Text(p.summary).font(.callout)
                if p.pushPeaksDB.isEmpty && p.swipeLeftLags.isEmpty && p.swipeRightLags.isEmpty {
                    Label("No gestures were recorded, so only the room noise was used.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Save") { session.save() }.keyboardShortcut(.defaultAction)
                Button("Start over") { session.begin() }
            }
        case .saved:
            Label("Saved. Wave now uses your thresholds.", systemImage: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(.green)
            Text("You can still fine-tune with the sensitivity slider.")
        }
    }

    private var gestureHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Push: move your open hand toward the screen and straight back, about half a second.", systemImage: "hand.point.up.left.fill")
            if session.layout.isStereo {
                Label("Swipe: move your hand briskly sideways across the laptop, 15–30 cm in front of the screen.", systemImage: "arrow.left.and.right")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func title(for kind: GestureEvent.Kind) -> String {
        switch kind {
        case .push: return "Push \(session.target) times"
        case .swipeLeft: return "Swipe left \(session.target) times"
        case .swipeRight: return "Swipe right \(session.target) times"
        case .grab: return "Grab \(session.target) times"
        case .pull: return "Pull \(session.target) times"
        }
    }

    private func instructions(for kind: GestureEvent.Kind) -> String {
        switch kind {
        case .push: return "Toward the screen and straight back, about half a second each. Pause between pushes."
        case .swipeLeft: return "Move your hand from the right side of the laptop to the left, briskly. Pause between swipes."
        case .swipeRight: return "Move your hand from the left side of the laptop to the right, briskly. Pause between swipes."
        case .grab: return "Hold your open hand up about 20 cm in front of the screen, then close it into a fist quickly and firmly — Wave hears your fingers snap onto your palm. Open it, wait a couple of seconds, and repeat."
        case .pull: return "Start close to the screen, move your hand away and straight back."
        }
    }
}

// MARK: - Labeled samples

@MainActor
@Observable
final class SampleRecorderModel {
    static let labels = ["push", "swipe_left", "swipe_right", "grab", "none"]

    let model: AppModel
    var label = "push"
    private(set) var running = false
    private(set) var samples: [LabeledSample] = []
    private(set) var lastExport: URL?
    private(set) var error: String?
    @ObservationIgnored private let recorder = FeatureWindowRecorder()
    @ObservationIgnored private var lastNoneCapture = 0.0
    @ObservationIgnored private var lastEventEnd = -Double.infinity

    init(model: AppModel) { self.model = model }

    func count(_ label: String) -> Int { samples.filter { $0.label == label }.count }

    func start() {
        guard !running else { return }
        running = true
        model.beginExclusive(.sampling, settings: model.prefs.engineSettings) { [weak self] out in
            self?.ingest(out.frames, out.events)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        model.endExclusive()
    }

    private func ingest(_ frames: [PipelineFrame], _ events: [GestureEvent]) {
        recorder.append(frames)
        guard let latest = recorder.latestTime else { return }
        if label == "none" {
            if latest - lastNoneCapture > 2 {
                lastNoneCapture = latest
                capture(endingAt: latest)
            }
            return
        }
        // Every gesture candidate (accepted or not) becomes a sample with the chosen label.
        for e in events where e.outcome != .oneSided && e.end - lastEventEnd > 0.4 {
            lastEventEnd = e.end
            capture(endingAt: min(latest, e.end + 0.15))
        }
    }

    private func capture(endingAt t: Double) {
        let pilots = model.prefs.pilotLayout.frequencies
        if let s = recorder.window(endingAt: t, label: label, pilots: pilots) { samples.append(s) }
    }

    func undo() { if !samples.isEmpty { samples.removeLast() } }
    func clear() { samples.removeAll() }

    func export() {
        do {
            let urls = try SampleExport.write(samples)
            lastExport = urls.json
            NSWorkspace.shared.activateFileViewerSelecting([urls.json, urls.csv])
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SampleRecorderView: View {
    @Bindable var recorder: SampleRecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Labeled samples").font(.title2.bold())
            Text("Pick a label, press Start, then do that gesture (or nothing, for “none”) several times. Each detected movement saves a 1.2 s window of features — never audio. Gestures don't trigger actions while recording.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Label", selection: $recorder.label) {
                ForEach(SampleRecorderModel.labels, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                if recorder.running {
                    Button("Stop") { recorder.stop() }
                    ProgressView().controlSize(.small)
                    Text("Recording “\(recorder.label)”…").foregroundStyle(.secondary)
                } else {
                    Button("Start") { recorder.start() }.keyboardShortcut(.defaultAction)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(SampleRecorderModel.labels, id: \.self) { l in
                    GridRow {
                        Text(l)
                        Text("\(recorder.count(l))").monospacedDigit()
                    }
                }
            }
            HStack {
                Button("Undo last") { recorder.undo() }.disabled(recorder.samples.isEmpty)
                Button("Clear") { recorder.clear() }.disabled(recorder.samples.isEmpty)
                Spacer()
                Button("Export JSON + CSV…") { recorder.export() }.disabled(recorder.samples.isEmpty)
            }
            if let url = recorder.lastExport { Text("Saved to \(url.deletingLastPathComponent().path)").font(.caption).foregroundStyle(.secondary) }
            if let e = recorder.error { Text(e).foregroundStyle(.red).font(.caption) }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 380)
    }
}
