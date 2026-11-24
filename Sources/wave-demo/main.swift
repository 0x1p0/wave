import AppKit
import SwiftUI

// Guided gesture session for tuning and demo videos. Launch from Terminal (it has microphone access):
//   open scripts/session.command      (or: make session)
// Saves to ~/Library/Application Support/Wave/Sessions/<time>/: session.json (every detection with its
// reason and time), one raw-audio .caf + .json per step (with keyboard/trackpad times), and webcam
// snapshots (camera/<seconds>.jpg, 4 per second). Uses the same pilot layout as the Wave app.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let session = DemoSession()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Wave — gesture session"
        window.contentView = NSHostingView(rootView: DemoView(session: session))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        Task { await session.run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Closing early still saves what was recorded (finalised video, log) before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await session.finishEarly()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    source.resume()
    signalSources.append(source)
}
app.run()
