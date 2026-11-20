import SwiftUI
import WaveCore

/// Live, interactive gesture tutorial: lessons on the left; on the right the instructions, an animated
/// demo, and a live side view of the laptop and your hand as Wave senses it.
public struct TutorialView: View {
    @Bindable var model: TutorialModel
    var onClose: () -> Void

    public init(model: TutorialModel, onClose: @escaping () -> Void = {}) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                header
                LiveSonarView(model: model)
                    .frame(height: 250)
                meters
                feedbackRow
                Spacer(minLength: 0)
                footer
            }
            .padding(22)
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Learn Wave").font(.title3.bold()).padding(.bottom, 8)
            ForEach(Array(model.lessons.enumerated()), id: \.element.id) { i, lesson in
                Button { model.index = i } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.completed.contains(lesson.id) ? "checkmark.circle.fill" : lesson.symbol)
                            .foregroundStyle(model.completed.contains(lesson.id) ? .green : .accentColor)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(lesson.title).fontWeight(i == model.index ? .semibold : .regular)
                            if lesson.experimental { Text("experimental").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(i == model.index ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Label("Practice mode: gestures don't trigger actions here.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 210)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            GestureDemo(kind: model.lesson.kind)
                .frame(width: 120, height: 92)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.lesson.title).font(.title.bold())
                    if model.lesson.experimental {
                        Text("EXPERIMENTAL").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                    }
                }
                Text(model.lesson.instructions).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Meters

    private var meters: some View {
        HStack(spacing: 16) {
            Meter(title: "Toward", value: model.toward, color: .green)
            Meter(title: "Away", value: model.away, color: .orange)
            if model.lesson.kind == .grab || model.lesson.kind == .hover {
                Meter(title: "Finger motion", value: model.micro, color: .pink, mark: model.grabLine)
            }
            if model.lesson.kind == .swipe && model.lanes.count == 2 {
                Meter(title: "Left tone", value: model.lanes[0], color: .cyan)
                Meter(title: "Right tone", value: model.lanes[1], color: .purple)
            }
            if model.lesson.kind == .hover {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.dialTargetNames.indices.contains(model.practiceTarget) ? model.dialTargetNames[model.practiceTarget] : "Level") (practice) \(Int(model.practiceLevel * 100)) %")
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: model.practiceLevel).frame(width: 150)
                }
            }
        }
    }

    // MARK: Progress + coaching

    private var feedbackRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.lesson.kind == .hover {
                HStack(spacing: 14) {
                    ForEach(model.hoverChecklist, id: \.0) { item in
                        Label(item.0, systemImage: item.1 ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.1 ? .green : .secondary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(0..<model.lesson.goal, id: \.self) { i in
                        Image(systemName: i < model.progress ? "checkmark.circle.fill" : "circle")
                            .font(.title2).foregroundStyle(i < model.progress ? .green : .secondary)
                    }
                    Text(model.isComplete ? "Nice — on to the next one." : "Do it \(model.lesson.goal) times")
                        .foregroundStyle(.secondary).padding(.leading, 6)
                }
            }
            Text(model.feedback.isEmpty ? " " : model.feedback)
                .font(.title3.weight(.medium))
                .foregroundStyle(model.feedbackGood ? .green : .orange)
                .id(model.feedbackSerial)
                .transition(.opacity)
                .animation(.easeOut(duration: 0.2), value: model.feedbackSerial)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { model.back() }.disabled(model.index == 0)
            Spacer()
            if model.index + 1 < model.lessons.count {
                Button(model.isComplete ? "Next lesson" : "Skip") { model.next() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - Live side view

/// Side view: the laptop screen on the left sending out its (inaudible) waves, your hand on the right.
/// The hand moves with the motion Wave measures and glows green (toward) or orange (away).
struct LiveSonarView: View {
    let model: TutorialModel

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pos = model.handPosition, toward = model.toward, away = model.away, micro = model.micro
            let phase = model.phase, text = model.phaseText, ready = phase == .ready || phase == .grabbing
            Canvas { ctx, size in
                let screenX: CGFloat = 70
                let midY = size.height / 2
                // Background
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12),
                         with: .linearGradient(Gradient(colors: [Color(white: 0.10), Color(white: 0.16)]),
                                               startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                // Laptop: screen + base
                ctx.fill(Path(roundedRect: CGRect(x: screenX - 14, y: midY - 85, width: 14, height: 150), cornerRadius: 4),
                         with: .color(Color(white: 0.75)))
                ctx.fill(Path(roundedRect: CGRect(x: screenX - 14, y: midY + 65, width: 150, height: 8), cornerRadius: 3),
                         with: .color(Color(white: 0.6)))
                ctx.draw(Text("screen").font(.caption2).foregroundColor(.gray), at: CGPoint(x: screenX - 7, y: midY - 98))
                // Expanding sound waves (19 kHz, inaudible)
                for k in 0..<5 {
                    let r = CGFloat((t * 70 + Double(k) * 60).truncatingRemainder(dividingBy: 300))
                    var arc = Path()
                    arc.addArc(center: CGPoint(x: screenX, y: midY - 10), radius: r, startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
                    ctx.stroke(arc, with: .color(.cyan.opacity(0.35 * (1 - Double(r) / 300))), lineWidth: 2)
                }
                // Hand
                let near = screenX + 90, far = size.width - 90
                let x = near + (far - near) * CGFloat((pos + 1) / 2)
                let glow: Color = toward > away + 0.1 ? .green : (away > toward + 0.1 ? .orange : .white)
                let strength = max(toward, away)
                let glowRadius = 34 + CGFloat(strength) * 40
                ctx.fill(Path(ellipseIn: CGRect(x: x - glowRadius, y: midY - 10 - glowRadius, width: glowRadius * 2, height: glowRadius * 2)),
                         with: .radialGradient(Gradient(colors: [glow.opacity(0.15 + 0.5 * strength), .clear]),
                                               center: CGPoint(x: x, y: midY - 10), startRadius: 0, endRadius: glowRadius))
                // Finger-motion ring
                if micro > 0.45 {
                    let rr = 30 + CGFloat(micro) * 25
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - rr, y: midY - 10 - rr, width: rr * 2, height: rr * 2)),
                               with: .color(.pink.opacity(min(1, micro))), lineWidth: 2)
                }
                let hand = ctx.resolve(Image(systemName: ready ? "hand.raised.fill" : "hand.raised"))
                ctx.draw(hand, in: CGRect(x: x - 26, y: midY - 40, width: 52, height: 60))
                // Motion arrows
                if toward > 0.15 {
                    drawArrow(ctx, from: CGPoint(x: x - 40, y: midY + 40), to: CGPoint(x: x - 40 - 70 * toward, y: midY + 40), color: .green)
                }
                if away > 0.15 {
                    drawArrow(ctx, from: CGPoint(x: x + 40, y: midY + 40), to: CGPoint(x: x + 40 + 70 * away, y: midY + 40), color: .orange)
                }
                // Distance hint
                ctx.draw(Text("closer").font(.caption2).foregroundColor(.gray), at: CGPoint(x: near, y: size.height - 14))
                ctx.draw(Text("farther").font(.caption2).foregroundColor(.gray), at: CGPoint(x: far, y: size.height - 14))
                // State chip
                let chip = Text(text).font(.callout.weight(.semibold)).foregroundColor(ready ? .green : .white)
                ctx.draw(chip, at: CGPoint(x: size.width - 16, y: 20), anchor: .trailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func drawArrow(_ ctx: GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        var p = Path()
        p.move(to: from); p.addLine(to: to)
        let dir: CGFloat = to.x < from.x ? 1 : -1
        p.move(to: to); p.addLine(to: CGPoint(x: to.x + dir * 10, y: to.y - 7))
        p.move(to: to); p.addLine(to: CGPoint(x: to.x + dir * 10, y: to.y + 7))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }
}

// MARK: - Animated demo of each gesture

/// A small looping animation of what the hand should do (screen on the left).
struct GestureDemo: View {
    let kind: Lesson.Kind

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10), with: .color(.secondary.opacity(0.12)))
                ctx.fill(Path(roundedRect: CGRect(x: 10, y: 14, width: 6, height: size.height - 28), cornerRadius: 2), with: .color(.secondary))
                let (dx, dy, closed, label) = pose(t)
                let x = size.width * 0.55 + dx * size.width * 0.28
                let y = size.height * 0.45 + dy * size.height * 0.3
                let image = ctx.resolve(Image(systemName: closed ? "hand.raised.fingers.spread" : "hand.raised.fill"))
                let s: CGFloat = closed ? 26 : 34
                ctx.draw(image, in: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s * 1.15))
                ctx.draw(Text(label).font(.caption2).foregroundColor(.secondary), at: CGPoint(x: size.width / 2 + 6, y: size.height - 9))
            }
        }
    }

    /// (x offset −1 = at the screen, y offset, fist?, caption)
    private func pose(_ t: Double) -> (CGFloat, CGFloat, Bool, String) {
        let u = t.truncatingRemainder(dividingBy: 2.4) / 2.4
        func bump(_ a: Double, _ b: Double) -> Double {
            guard u > a && u < b else { return 0 }
            return 0.5 * (1 - cos(2 * Double.pi * (u - a) / (b - a)))
        }
        switch kind {
        case .sonar:
            return (CGFloat(0.4 * sin(2 * Double.pi * u)), 0, false, "move around")
        case .push:
            return (CGFloat(0.5 - 1.1 * bump(0.15, 0.55)), 0, false, "in & out")
        case .pull:
            return (CGFloat(-0.4 + 1.1 * bump(0.15, 0.55)), 0, false, "out & in")
        case .hover:
            let x = u < 0.25 ? 0.6 - 0.8 * (u / 0.25) : -0.2 - 0.5 * bump(0.45, 0.65) + 0.5 * bump(0.72, 0.92)
            return (CGFloat(x), 0, false, u < 0.4 ? "up & hold" : (u < 0.7 ? "push = up" : "pull = down"))
        case .grab:
            let x = u < 0.25 ? 0.6 - 0.8 * (u / 0.25) : -0.2
            return (CGFloat(x), 0, u > 0.55 && u < 0.9, u < 0.5 ? "up & hold" : "make a fist")
        case .swipe:
            let x = sin(2 * Double.pi * u)
            return (0.1, CGFloat(0), false, x > 0 ? "→ across" : "← across")
        }
    }
}

// MARK: - Meter

struct Meter: View {
    let title: String
    let value: Double
    let color: Color
    var mark: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.2))
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
                    if let mark {
                        Rectangle().fill(.primary).frame(width: 2, height: 14).offset(x: geo.size.width * CGFloat(min(1, mark)) - 1)
                    }
                }
            }
            .frame(width: 120, height: 10)
        }
    }
}
