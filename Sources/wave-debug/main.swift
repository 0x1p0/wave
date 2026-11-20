import AppKit
import SwiftUI
import WaveCore
import WaveUI

// Wave debug window (M1). Run from Terminal: the microphone permission belongs to the terminal app.
//
//   wave-debug                         live: plays the pilot, shows spectrogram + events
//   wave-debug --replay FILE.caf       replays a recording in real time (no mic, no pilot)
//   wave-debug --snapshot OUT.png [--replay FILE.caf] [--wait SEC]
//                                      renders the window to a PNG (replaying FILE instantly) and quits

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DebugModel()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot-tutorial"), i + 1 < args.count {
            snapshotTutorial(to: args[i + 1], args: args)
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: args[i + 1], args: args)
            return
        }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Wave Debug"
        window.contentView = NSHostingView(rootView: DebugWindowView(model: model))
        window.center()
        window.setFrameAutosaveName("WaveDebug")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        if let i = args.firstIndex(of: "--replay"), i + 1 < args.count {
            model.replay(URL(fileURLWithPath: args[i + 1]))  // real-time replay, no mic or pilot
            return
        }
        Task {
            if await MicCapture.requestPermission() {
                model.start()
            } else {
                let alert = NSAlert()
                alert.messageText = "Microphone access is off for this terminal app"
                alert.informativeText = "System Settings → Privacy & Security → Microphone, enable your terminal, then relaunch."
                alert.runModal()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }

    /// Renders the tutorial after feeding it a recording up to `--until` seconds (for checking the UI).
    private func snapshotTutorial(to path: String, args: [String]) {
        let kindName = args.firstIndex(of: "--lesson").map { args[$0 + 1] } ?? "push"
        let until = args.firstIndex(of: "--until").flatMap { Double(args[$0 + 1]) } ?? .infinity
        let kinds = Lesson.Kind.allCases
        let tutorial = TutorialModel(lessons: kinds)
        tutorial.index = kinds.firstIndex { $0.rawValue == kindName } ?? 1
        if let i = args.firstIndex(of: "--replay"), i + 1 < args.count,
           let recording = try? LoadedRecording.load(URL(fileURLWithPath: args[i + 1])) {
            _ = Replay.run(recording) { out in
                let frames = out.frames.filter { $0.time <= until }
                guard !frames.isEmpty else { return }
                let events = out.events.filter { $0.end <= until }
                tutorial.ingest(frames: frames, events: events, controls: out.controls, phase: out.interactionPhase)
            }
        }
        render(TutorialView(model: tutorial), size: NSSize(width: 940, height: 680), to: path, wait: 0.5)
    }

    private func render<V: View>(_ view: V, size: NSSize, to path: String, wait: Double) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
            try? png.write(to: URL(fileURLWithPath: path))
            print("Snapshot → \(path)")
            exit(0)
        }
    }

    private func snapshot(to path: String, args: [String]) {
        if let i = args.firstIndex(of: "--replay"), i + 1 < args.count {
            do {
                model.replayImmediately(try LoadedRecording.load(URL(fileURLWithPath: args[i + 1])))
            } catch {
                print("✗ \(error)")
                exit(1)
            }
        }
        let wait = args.firstIndex(of: "--wait").flatMap { Double(args[$0 + 1]) } ?? 0.5
        let size = NSSize(width: 1120, height: 820)
        let host = NSHostingView(rootView: DebugWindowView(model: model))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("Snapshot → \(path)")
                exit(0)
            } catch {
                print("✗ \(error)")
                exit(1)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Ctrl-C / kill: quit through AppKit so the engine fades the pilot out (no click) instead of dying mid-tone.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    source.resume()
    signalSources.append(source)
}
app.run()
