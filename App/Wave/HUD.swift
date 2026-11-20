import AppKit
import SwiftUI

/// Small on-screen confirmation near the top of the screen ("⏯ Play/Pause"), visible over full-screen
/// video, never takes focus or clicks.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var hideWork: DispatchWorkItem?

    func show(symbol: String, title: String, subtitle: String? = nil) {
        let view = HUDView(symbol: symbol, title: title, subtitle: subtitle)
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
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold))
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
