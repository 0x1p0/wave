import SwiftUI
import WaveCore

/// First-launch walkthrough: what Wave does, privacy, permissions, speakers, hearing test.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var page = 0
    @State private var hearing: HearingTest?

    private let pages = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: microphone
                case 2: speakers
                case 3: hearingTest
                case 4: accessibility
                default: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<pages, id: \.self) { i in
                        Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                if page < pages - 1 {
                    Button("Next") { page += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Finish") {
                        model.prefs.hasCompletedOnboarding = true
                        model.windows.close(.onboarding)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "hand.wave.fill").font(.system(size: 40)).foregroundStyle(.tint)
                Text("Welcome to Wave").font(.largeTitle.bold())
            }
            Text("Control playback by moving your hand in the air near your MacBook. Push your hand toward the screen and back to play or pause — no camera, no extra hardware.")
                .font(.title3)
            Text("How it works: the MacBook speakers play a very high tone you shouldn't hear, the microphones pick up its echo off your hand, and the change in pitch (Doppler shift) shows how your hand moved.")
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Audio never leaves your Mac and is never saved to disk — except debug recordings you start yourself.", systemImage: "lock.fill")
                    Label {
                        Text("The orange microphone dot in the menu bar is on whenever Wave is listening. That's Wave hearing its own tone.")
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(.orange)
                    }
                    Label("By default Wave only listens while something is playing, so the dot is off the rest of the time.", systemImage: "play.circle")
                }
                .padding(6)
            }
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Microphone").font(.largeTitle.bold())
            Text("Wave needs the microphone to hear its tone's echo. It analyses the sound in memory and keeps nothing.")
            status(model.micPermission == .authorized, ok: "Microphone access granted", bad: "Not granted yet")
            if model.micPermission == .notDetermined {
                Button("Allow microphone access") { model.requestMicrophone() }
            } else if model.micPermission != .authorized {
                Text("Turn on Wave in System Settings → Privacy & Security → Microphone.").foregroundStyle(.secondary)
                Button("Open Microphone settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private var speakers: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speakers").font(.largeTitle.bold())
            Text("The tone always plays through the MacBook's own speakers, even when your audio goes to AirPods or headphones. They need to be unmuted, around half volume.")
            Text("Your volume keys change whatever you're listening on, so if you use headphones the MacBook speakers keep their own volume. Wave adjusts the tone for it, and pauses with “Volume too low for Wave” if it can't.")
                .foregroundStyle(.secondary)
            if let v = model.speakerVolume {
                status(!model.speakersTooQuiet, ok: "MacBook speakers at \(Int((v * 100).rounded())) %",
                       bad: model.speakerMuted ? "MacBook speakers are muted" : "MacBook speakers at \(Int((v * 100).rounded())) % — too quiet")
            }
            if model.speakersTooQuiet {
                Button("Set MacBook speakers to 50 %") { model.setSpeakers(to: 0.5) }
            }
        }
    }

    private var hearingTest: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Can you hear it?").font(.largeTitle.bold())
            Text("Most adults can't hear Wave's tone, but some people (especially younger ones) can. Let's check, and move to a higher tone if needed.")
            if let hearing {
                HearingTestView(test: hearing) { self.hearing = nil }
            } else {
                Button("Run the hearing test") { hearing = HearingTest(model: model) }
                Text("Uses \(model.prefs.pilotLayout.description). You can skip this and run it later from Settings → Sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accessibility: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Media keys").font(.largeTitle.bold())
            Text("To play and pause, Wave presses the system Play/Pause key for you, just like the key on your keyboard. macOS asks you to allow that under Accessibility.")
            status(model.accessibilityTrusted, ok: "Accessibility allowed", bad: "Not allowed yet")
            if !model.accessibilityTrusted {
                Button("Open Accessibility settings") { model.requestAccessibility() }
                Text("Turn on Wave in the list. This page updates by itself.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var finish: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're set").font(.largeTitle.bold())
            Text("Play a video, then push your hand toward the screen and back. A small confirmation appears at the top of the screen.")
            Toggle("Only listen while media is playing", isOn: $model.prefs.onlyWhileMediaPlaying)
            Toggle("Launch Wave at login", isOn: Binding(
                get: { model.loginItemStatus == .enabled },
                set: { model.setLaunchAtLogin($0) }))
            HStack {
                Button("Open the gesture tutorial…") { model.showTutorial() }
                Text("Live practice: see your hand the way Wave does.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Calibrate now…") { model.showCalibration() }
                Text("Optional: tunes the thresholds to your room and hand.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Wave lives in the menu bar (the hand icon).").foregroundStyle(.secondary)
        }
    }

    private func status(_ ok: Bool, ok okText: String, bad badText: String) -> some View {
        Label(ok ? okText : badText, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? .green : .orange)
            .font(.headline)
    }
}
