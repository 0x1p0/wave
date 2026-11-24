import SwiftUI
import WaveCore
import WaveUI

/// The session window: what to do now (big), your webcam, and Wave's live view of your hand.
struct DemoView: View {
    let session: DemoSession
    @State private var typed = ""
    @FocusState private var typingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 16) {
                camera
                VStack(alignment: .leading, spacing: 12) {
                    LiveSonarView(model: session.tutorial)
                        .frame(height: 290)
                    HStack(spacing: 16) {
                        Meter(title: "Toward", value: session.tutorial.toward, color: .green)
                        Meter(title: "Away", value: session.tutorial.away, color: .orange)
                        Meter(title: "Snap", value: session.tutorial.snap, color: .pink, mark: session.tutorial.grabLine)
                        if session.tutorial.lanes.count == 2 {
                            Meter(title: "Left tone", value: session.tutorial.lanes[0], color: .cyan)
                            Meter(title: "Right tone", value: session.tutorial.lanes[1], color: .purple)
                        }
                    }
                    feed
                }
            }
            Spacer(minLength: 0)
            HStack {
                Label("Recording sonar audio, detections and webcam to your Mac for tuning. Nothing leaves it.", systemImage: "record.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(session.engineStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(minWidth: 1240, minHeight: 800)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header: what to do now

    @ViewBuilder private var header: some View {
        switch session.phase {
        case .waitingForStart:
            VStack(alignment: .leading, spacing: 10) {
                Text("Ready when you are").font(.system(size: 40, weight: .bold))
                Text("1. Start your screen recording.   2. Click Start.   Then follow the big instructions — about 4 minutes. Wave runs with your exact settings; nothing actually happens on your Mac.")
                    .font(.title2)
                Button {
                    session.begin()
                } label: {
                    Text("Start").font(.system(size: 26, weight: .bold)).padding(.horizontal, 40).padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
            }
        case .starting(let text):
            Text(text).font(.system(size: 34, weight: .bold))
        case .getReady(let i, let remaining):
            let step = DemoSession.steps[i]
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Next — step \(i + 1) of \(DemoSession.steps.count)").font(.title2).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(remaining)").font(.system(size: 54, weight: .heavy)).monospacedDigit().foregroundStyle(.orange)
                }
                Text(step.title).font(.system(size: 40, weight: .bold))
                Text(step.instruction).font(.title2)
            }
        case .running(let i):
            let step = DemoSession.steps[i]
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Step \(i + 1) of \(DemoSession.steps.count)").font(.title2).foregroundStyle(.secondary)
                    Text("● GO").font(.title2.bold()).foregroundStyle(.red)
                    Spacer()
                    Text("\(Int(session.stepRemaining.rounded(.up))) s").font(.system(size: 54, weight: .heavy)).monospacedDigit()
                }
                Text(step.title).font(.system(size: 40, weight: .bold))
                Text(step.instruction).font(.title2)
                if step.typing {
                    TextEditor(text: $typed)
                        .font(.title3)
                        .frame(height: 90)
                        .focused($typingFocused)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
                        .onAppear { typingFocused = true }
                } else {
                    progress(for: step)
                }
            }
        case .finished(let text):
            Text(text).font(.system(size: 28, weight: .bold)).foregroundStyle(.green)
        case .failed(let text):
            Text(text).font(.system(size: 28, weight: .bold)).foregroundStyle(.red)
        }
    }

    @ViewBuilder private func progress(for step: DemoSession.Step) -> some View {
        let t = session.tutorial
        if step.lesson == .hover {
            HStack(spacing: 16) {
                ForEach(t.hoverChecklist, id: \.0) { item in
                    Label(item.0, systemImage: item.1 ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(item.1 ? .green : .secondary)
                }
            }
        } else if step.lesson != .sonar {
            HStack(spacing: 8) {
                ForEach(0..<t.lesson.goal, id: \.self) { i in
                    Image(systemName: i < t.progress ? "checkmark.circle.fill" : "circle")
                        .font(.title).foregroundStyle(i < t.progress ? .green : .secondary)
                }
                if !t.feedback.isEmpty {
                    Text(t.feedback).font(.title3.weight(.medium))
                        .foregroundStyle(t.feedbackGood ? .green : .orange).padding(.leading, 8)
                }
            }
        }
    }

    // MARK: Camera with the latest detection on top

    private var camera: some View {
        ZStack(alignment: .bottom) {
            if session.cameraOn {
                CameraPreview(session: session.camera.session)
            } else {
                Color.black
                Text("Camera off").foregroundStyle(.secondary).padding()
            }
            if let toast = session.toast, session.sessionTime - toast.time < 1.6 {
                Text(toast.text)
                    .font(.system(size: 30, weight: .heavy))
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(toast.good ? .green : .orange)
                    .padding(16)
            }
        }
        .frame(width: 560, height: 420)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What Wave detected").font(.headline)
            ForEach(session.feed) { item in
                Text(item.text).font(.system(.callout, design: .monospaced))
                    .foregroundStyle(item.good ? .green : .orange)
            }
        }
    }
}
