import AppKit
import SwiftUI
import WaveCore
import WaveUI

/// `Wave.app/Contents/MacOS/Wave --snapshots DIR`: draws the menu, the on-screen confirmations and Settings to
/// PNGs (light and dark) and quits, without listening. For checking the UI without clicking around.
@MainActor
enum Snapshots {
    static func run(to dir: URL, model: AppModel) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.prepareForSnapshot()
        let hints = [HUDHint(gesture: "Push", effect: "＋"), HUDHint(gesture: "Pull", effect: "−"),
                     HUDHint(gesture: "Hold still", effect: "Brightness"), HUDHint(gesture: "Move away", effect: "done")]
        var items: [(String, AnyView, NSSize?)] = [
            ("menu", AnyView(MenuView(model: model)), nil),
            ("hud-push", AnyView(HUDView(symbol: "playpause.fill", title: "Play/Pause", subtitle: "Push", tint: .blue)), nil),
            ("hud-swipe", AnyView(HUDView(symbol: SystemAction.nextDesktop.symbol, title: "Next desktop", subtitle: "Swipe left",
                                          tint: .teal)), nil),
            ("hud-volume", AnyView(HUDView(symbol: "speaker.wave.2.fill", title: "Volume", subtitle: "Hover control", level: 0.6,
                                           tint: .pink, hints: hints)), nil),
        ]
        let tutorial = TutorialModel(lessons: [.sonar, .push, .pull, .hover, .grab, .swipe], dialTargetNames: ["Volume", "Brightness"])
        items.append(("tutorial", AnyView(TutorialView(model: tutorial)), NSSize(width: 940, height: 680)))
        items.append(("onboarding", AnyView(OnboardingView(model: model)), NSSize(width: 620, height: 520)))
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (name, view, size) in items {
                render(view, size: size, appearance: NSAppearance(named: appearance)!,
                       to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
            for (name, tab) in [("gestures", AppModel.SettingsTab.gestures), ("apps", .apps), ("letters", .letters), ("hover", .hover)] {
                model.settingsTab = tab
                render(AnyView(SettingsView(model: model)), size: NSSize(width: 880, height: 1150),
                       appearance: NSAppearance(named: appearance)!, to: dir.appendingPathComponent("settings-\(name)-\(suffix).png"))
            }
        }
    }

    private static func render(_ view: AnyView, size: NSSize?, appearance: NSAppearance, to url: URL) {
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size ?? NSSize(width: 400, height: 300)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        if size == nil { window.setContentSize(hosting.fittingSize) }
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))  // let Forms and pickers finish laying out
        hosting.display()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
