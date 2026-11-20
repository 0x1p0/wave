import AppKit
import SwiftUI

@main
struct WaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    let model: AppModel
    var body: some View {
        Image(systemName: model.menuSymbol)
            .accessibilityLabel("Wave: \(model.statusText)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ctrl-C / kill: quit through AppKit so the pilot fades out instead of stopping with a click.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        model.launch()
        // `open Wave.app --args --tutorial` opens the gesture tutorial straight away.
        if CommandLine.arguments.contains("--tutorial") { model.showTutorial() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
