import SwiftUI
import WaveCore

/// Shared time axis: the last `capacity` frames, newest at the right edge. A plain value so the
/// (non-isolated) Canvas renderer can use it.
struct TimeAxis: Sendable {
    let left: Double
    let window: Double
    var right: Double { left + window }

    @MainActor
    init(history: FeatureHistory, frameRate: Double) {
        window = Double(history.capacity) / frameRate
        left = (history.newestTime ?? window) - window
    }

    func x(_ t: Double, width: CGFloat) -> CGFloat { CGFloat((t - left) / window) * width }
}

/// Visible traces in time order, copied out of the main-actor history for drawing.
struct TraceSnapshot: Sendable {
    var times: [Double] = []
    var toward: [Float] = []
    var away: [Float] = []
    var reference: [Float] = []
    var velocity: [Float] = []

    @MainActor
    init(_ h: FeatureHistory) {
        for i in 0..<h.count {
            let r = h.ring(i)
            times.append(h.times[r]); toward.append(h.toward[r]); away.append(h.away[r])
            reference.append(h.reference[r]); velocity.append(h.velocity[r])
        }
    }
}

/// Scrolling spectrogram of the band around the pilot, with gesture markers.
struct SpectrogramView: View {
    let model: DebugModel
    var frameRate = 48_000.0 / 512

    var body: some View {
        let _ = model.revision
        let axis = TimeAxis(history: model.history, frameRate: frameRate)
        let events = model.events
        let hz = Int(Double(model.history.halfWidth) * 48_000 / 4096)
        ZStack {
            Color.black
            if let image = model.history.spectrogramImage() {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
            }
            Canvas { ctx, size in
                // Pilot centre line and band labels.
                let mid = size.height / 2
                var line = Path()
                line.move(to: CGPoint(x: 0, y: mid)); line.addLine(to: CGPoint(x: size.width, y: mid))
                ctx.stroke(line, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                drawEventMarkers(ctx, size: size, axis: axis, events: events)
                ctx.draw(Text("toward ↑").font(.caption2).foregroundColor(.white.opacity(0.7)), at: CGPoint(x: 34, y: 10))
                ctx.draw(Text("away ↓").font(.caption2).foregroundColor(.white.opacity(0.7)), at: CGPoint(x: 28, y: size.height - 10))
                ctx.draw(Text("+\(hz) Hz").font(.caption2).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: size.width - 30, y: 10))
                ctx.draw(Text("−\(hz) Hz").font(.caption2).foregroundColor(.white.opacity(0.5)), at: CGPoint(x: size.width - 30, y: size.height - 10))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Toward/away/reference energy (dB over baseline) with detector thresholds, plus Doppler velocity.
struct FeatureTraceView: View {
    let model: DebugModel
    var frameRate = 48_000.0 / 512

    var body: some View {
        let _ = model.revision
        let axis = TimeAxis(history: model.history, frameRate: frameRate)
        let config = model.detectorConfig
        let h = TraceSnapshot(model.history)
        let events = model.events
        Canvas { ctx, size in
            let energyHeight = size.height * 0.68
            let velTop = energyHeight + 6
            let velHeight = size.height - velTop
            let dbMin: Float = -6, dbMax: Float = 30
            func yDB(_ v: Float) -> CGFloat { energyHeight * CGFloat(1 - (min(max(v, dbMin), dbMax) - dbMin) / (dbMax - dbMin)) }
            func yV(_ v: Float) -> CGFloat { velTop + velHeight * CGFloat(0.5 - min(max(v, -2), 2) / 4) }

            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: energyHeight)), with: .color(Color(nsColor: .textBackgroundColor)))
            ctx.fill(Path(CGRect(x: 0, y: velTop, width: size.width, height: velHeight)), with: .color(Color(nsColor: .textBackgroundColor)))

            // Grid + thresholds.
            for db in stride(from: Float(0), through: 30, by: 10) {
                hline(ctx, y: yDB(db), width: size.width, color: .secondary.opacity(0.2))
                ctx.draw(Text("\(Int(db))").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: 10, y: yDB(db) - 6))
            }
            hline(ctx, y: yDB(config.effectiveOnDB), width: size.width, color: .blue.opacity(0.6), dash: [5, 3])
            hline(ctx, y: yDB(config.effectiveMinPeakDB), width: size.width, color: .purple.opacity(0.6), dash: [2, 3])
            hline(ctx, y: yV(0), width: size.width, color: .secondary.opacity(0.3))
            hline(ctx, y: yV(config.minVelocity), width: size.width, color: .secondary.opacity(0.25), dash: [3, 3])
            hline(ctx, y: yV(-config.minVelocity), width: size.width, color: .secondary.opacity(0.25), dash: [3, 3])

            func trace(_ values: [Float], _ color: Color, _ y: (Float) -> CGFloat) {
                guard h.times.count > 1 else { return }
                var p = Path()
                for i in h.times.indices {
                    let pt = CGPoint(x: axis.x(h.times[i], width: size.width), y: y(values[i]))
                    i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                }
                ctx.stroke(p, with: .color(color), lineWidth: 1.3)
            }
            trace(h.reference, .gray, yDB)
            trace(h.away, .orange, yDB)
            trace(h.toward, .green, yDB)
            trace(h.velocity, .blue, yV)
            drawEventMarkers(ctx, size: size, axis: axis, events: events)

            // Legend.
            let legend = [("toward", Color.green), ("away", .orange), ("reference", .gray),
                          ("on threshold", .blue), ("min peak", .purple)]
            var x: CGFloat = 30
            for (name, color) in legend {
                ctx.fill(Path(CGRect(x: x, y: 4, width: 10, height: 3)), with: .color(color))
                ctx.draw(Text(name).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x + 14, y: 5), anchor: .leading)
                x += 92
            }
            ctx.draw(Text("velocity (m/s, + toward)").font(.system(size: 9)).foregroundColor(.blue),
                     at: CGPoint(x: 30, y: velTop + 7), anchor: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func hline(_ ctx: GraphicsContext, y: CGFloat, width: CGFloat, color: Color, dash: [CGFloat] = []) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: width, y: y))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
    }
}

/// Shaded span + label for each event inside the visible window.
func drawEventMarkers(_ ctx: GraphicsContext, size: CGSize, axis: TimeAxis, events: [GestureEvent]) {
    for e in events where e.end >= axis.left && e.start <= axis.right {
        let x0 = max(0, axis.x(e.start, width: size.width))
        let x1 = min(size.width, axis.x(e.end, width: size.width))
        let color: Color = e.isAccepted ? .green : .red
        ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: size.height)), with: .color(color.opacity(0.12)))
        var p = Path()
        p.move(to: CGPoint(x: x1, y: 0)); p.addLine(to: CGPoint(x: x1, y: size.height))
        ctx.stroke(p, with: .color(color.opacity(0.8)), lineWidth: 1.5)
        let label = e.isAccepted ? String(format: "PUSH %.2f", e.confidence) : e.outcome.rawValue
        ctx.draw(Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(color),
                 at: CGPoint(x: x1 - 3, y: 18), anchor: .trailing)
    }
}
