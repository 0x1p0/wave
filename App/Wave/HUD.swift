import AppKit
import SwiftUI

/// Small on-screen confirmation near the top of the screen ("⏯ Play/Pause"), visible over full-screen
/// video, never takes focus or clicks.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var hideWork: DispatchWorkItem?

    /// `level` (0…1) adds a bar; `sticky` keeps it up until `hide(after:)`.
    func show(symbol: String, title: String, subtitle: String? = nil, level: Float? = nil, sticky: Bool = false) {
        let view = HUDView(symbol: symbol, title: title, subtitle: subtitle, level: level)
        let panel = self.panel ?? makePanel()
        if let hosting {
            hosting.rootView = view
        } else {
            let h = NSHostingView(rootView: view)
            panel.contentView = h
            hosting = h
        }
        hosting?.layoutSubtreeIfNeeded()
        let size = hosting?.fittingSize ?? NSSize(width: 220, height: 56)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.frame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 64,
                                  width: size.width, height: size.height), display: true)
        }
        hideWork?.cancel()
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        if !sticky { hide(after: 0.9) }
    }

    func hide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        panel = p
        return p
    }
}

struct HUDView: View {
    let symbol: String
    let title: String
    let subtitle: String?
    var level: Float? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                if let level {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.25))
                            Capsule().fill(.primary).frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
                        }
                    }
                    .frame(width: 180, height: 6)
                }
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .fixedSize()
        .padding(8)
    }
}
