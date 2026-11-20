// Renders Wave's app icon (SF Symbol hand + echo arcs on a gradient) into the asset catalog.
// Usage: swift scripts/make-icon.swift App/Wave/Assets.xcassets
import AppKit

let catalog = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Wave/Assets.xcassets")
let iconset = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: ~80 % body with rounded corners.
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.86, alpha: 1),
                        NSColor(calibratedRed: 0.27, green: 0.20, blue: 0.78, alpha: 1)])!
        .draw(in: shape, angle: -60)

    // Echo arcs on the right.
    NSColor.white.withAlphaComponent(0.55).setStroke()
    for (i, r) in [0.20, 0.27, 0.34].enumerated() {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: body.minX + body.width * 0.42, y: body.midY), radius: body.width * r,
                      startAngle: -32, endAngle: 32)
        arc.lineWidth = max(1, body.width * 0.035)
        arc.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.65 - 0.17 * CGFloat(i)).setStroke()
        arc.stroke()
    }

    let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.48, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let hand = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = hand.size
        hand.draw(in: NSRect(x: body.minX + body.width * 0.36 - size.width / 2, y: body.midY - size.height / 2,
                             width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(points * scale).write(to: iconset.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconset.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": ["version": 1, "author": "xcode"]], options: [.prettyPrinted])
    .write(to: catalog.appendingPathComponent("Contents.json"))
print("Wrote \(iconset.path)")
