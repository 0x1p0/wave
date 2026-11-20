import SwiftUI
import WaveCore

/// "Can you hear the tone?" Plays Wave's tone for a few seconds; if the user hears it, tries a higher one.
@MainActor
@Observable
final class HearingTest {
    enum Phase: Equatable { case ready, playing, asking, finished(String), failed(String) }

    let model: AppModel
    private(set) var phase: Phase = .ready
    private(set) var candidates: [PilotLayout]
    private(set) var index = 0
    @ObservationIgnored private var player: PilotPlayer?
    @ObservationIgnored private var pending: DispatchWorkItem?

    var current: PilotLayout { candidates[index] }

    init(model: AppModel) {
        self.model = model
        if model.prefs.swipesEnabled {
            let l = model.prefs.leftPilotHz, r = model.prefs.rightPilotHz
            candidates = [.stereo(left: l, right: r), .stereo(left: max(l, 19_000), right: max(r, 19_250) + 250)]
        } else {
            let f = model.prefs.pushPilotHz
            candidates = [f, 19_000, 19_250, 19_500].filter { $0 >= f }.reduce(into: [Double]()) { if !$0.contains($1) { $0.append($1) } }
                .map { PilotLayout.single($0) }
        }
    }

    func play() {
        let decision = model.prefs.engineSettings.level.decide(speakerGainDB: model.speakerGainDB, muted: model.speakerMuted)
        guard let amplitude = decision.amplitudeDBFS, let speakers = AudioDevices.builtInSpeakers() else {
            phase = .failed("The MacBook speakers are muted or too quiet. Set them to 50 % first.")
            return
        }
        model.beginHearingTest()
        phase = .playing
        let layout = current
        // Let the engine's pilot fade out first.
        schedule(after: 0.4) { [weak self] in
            guard let self else { return }
            do {
                let player = try PilotPlayer(device: speakers)
                let tones: [PilotTone]
                switch layout {
                case .single(let f): tones = [PilotTone(frequency: f)]
                case .stereo(let l, let r): tones = [PilotTone(frequency: l, leftGain: 1, rightGain: 0),
                                                      PilotTone(frequency: r, leftGain: 0, rightGain: 1)]
                }
                try player.start(tones: tones, amplitude: Float(pow(10, amplitude / 20)))
                self.player = player
                self.schedule(after: 3.5) { [weak self] in
                    self?.player?.stop()
                    self?.player = nil
                    self?.phase = .asking
                }
            } catch {
                self.phase = .failed("Couldn't play the tone: \(error)")
                self.model.endHearingTest()
            }
        }
    }

    func answer(heard: Bool) {
        if heard {
            if index + 1 < candidates.count {
                index += 1
                play()
            } else {
                apply(current)
                finish("You can hear even the highest tone Wave can use, so it may be faintly audible to you. Keep the level low.")
            }
        } else {
            apply(current)
            finish("Wave will use \(current.description), which you can't hear.")
        }
    }

    func cancel() {
        pending?.cancel()
        player?.stop()
        player = nil
        if phase == .playing || phase == .asking { model.endHearingTest() }
        phase = .ready
    }

    private func finish(_ message: String) {
        phase = .finished(message)
        model.endHearingTest()
    }

    private func apply(_ layout: PilotLayout) {
        switch layout {
        case .single(let f): model.prefs.pushPilotHz = f
        case .stereo(let l, let r):
            model.prefs.leftPilotHz = l
            model.prefs.rightPilotHz = r
        }
    }

    private func schedule(after seconds: Double, _ body: @escaping @MainActor () -> Void) {
        let work = DispatchWorkItem { MainActor.assumeIsolated { body() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

struct HearingTestView: View {
    let test: HearingTest
    var onDone: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch test.phase {
            case .ready:
                Text("Sit as usual and listen closely. Wave will play its tone (\(test.current.description)) for 3 seconds.")
                HStack {
                    Button("Play tone") { test.play() }.keyboardShortcut(.defaultAction)
                    Button("Cancel") { test.cancel(); onDone() }
                }
            case .playing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Playing \(test.current.description)… listen.")
                }
            case .asking:
                Text("Did you hear a tone (\(test.current.description))?")
                HStack {
                    Button("I heard it") { test.answer(heard: true) }
                    Button("I heard nothing") { test.answer(heard: false) }.keyboardShortcut(.defaultAction)
                    Button("Play again") { test.play() }
                }
            case .finished(let message):
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Done") { onDone() }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("OK") { test.cancel(); onDone() }
            }
        }
        .onDisappear { if test.phase == .playing || test.phase == .asking { test.cancel() } }
    }
}
