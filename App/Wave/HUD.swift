import AppKit
import SwiftUI

/// The on-screen confirmation near the top of the screen ("Play/Pause · Push"). Floats over full-screen video,
/// never takes focus or clicks.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<HUDView>?
    private var hideWork: DispatchWorkItem?

    /// `level` (0…1) adds a bar; `hints` adds small "what you can do now" chips; `sticky` keeps it up until
    /// `hide(after:)`.
    func show(symbol: String, title: String, subtitle: String? = nil, level: Float? = nil, tint: Color = .accentColor,
              hints: [HUDHint] = [], sticky: Bool = false) {
        let view = HUDView(symbol: symbol, title: title, subtitle: subtitle, level: level, tint: tint, hints: hints)
        let panel = self.panel ?? makePanel()
        if let hosting {
            hosting.rootView = view
        } else {
            let h = NSHostingView(rootView: view)
            panel.contentView = h
            hosting = h
        }
        hosting?.layoutSubtreeIfNeeded()
        let size = hosting?.fittingSize ?? NSSize(width: 300, height: 70)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 18,
                                  width: size.width, height: size.height), display: true)
        }
        hideWork?.cancel()
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
        if !sticky { hide(after: 1.1) }
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
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 70),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false  // the view draws its own soft shadow
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        panel = p
        return p
    }
}

/// A "what you can do now" chip: a gesture and its effect ("Push" "＋").
struct HUDHint: Hashable {
    let gesture: String
    let effect: String
}

struct HUDView: View {
    let symbol: String
    let title: String
    let subtitle: String?
    var level: Float? = nil
    var tint: Color = .accentColor
    var hints: [HUDHint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                GestureBadge(symbol: symbol, tint: tint, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                if let level {
                    Text("\(Int((level * 100).rounded())) %")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            if let level {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.12))
                        Capsule().fill(tint.gradient)
                            .frame(width: max(6, geo.size.width * CGFloat(min(1, max(0, level)))))
                    }
                }
                .frame(height: 6)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: level)
            }
            if !hints.isEmpty {
                HStack(spacing: 6) {
                    ForEach(hints, id: \.self) { hint in
                        HStack(spacing: 4) {
                            Text(hint.gesture).foregroundStyle(.primary)
                            Text(hint.effect).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.primary.opacity(0.07), in: Capsule())
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: level == nil && hints.isEmpty ? 240 : 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .fixedSize()
        .padding(24)  // room for the shadow
    }
}
