// Contact sheet of webcam snapshots: swift scripts/contact-sheet.swift OUT.png CAMERA_DIR COLS t1[:label] t2[:label] …
// Picks the snapshot nearest each time (seconds on the session clock); labels each tile with its time and label.
import AppKit

let args = CommandLine.arguments
guard args.count >= 5, let cols = Int(args[3]) else {
    print("usage: contact-sheet.swift OUT.png CAMERA_DIR COLS t1[:label] …"); exit(1)
}
let out = args[1], dir = args[2]
let items: [(Double, String)] = args.dropFirst(4).compactMap { a in
    let parts = a.split(separator: ":", maxSplits: 1).map(String.init)
    return Double(parts[0]).map { ($0, parts.count > 1 ? parts[1] : "") }
}
let files = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".jpg") }) ?? []
let stamps = files.compactMap { f -> (Double, String)? in Double(f.dropLast(4)).map { ($0, f) } }
let w = 240, h = 180, pad = 34
let rows = (items.count + cols - 1) / cols
let img = NSImage(size: NSSize(width: cols * w, height: rows * (h + pad)))
img.lockFocus()
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: cols * w, height: rows * (h + pad)).fill()
for (i, item) in items.enumerated() {
    let x = (i % cols) * w, y = (rows - 1 - i / cols) * (h + pad)
    if let best = stamps.min(by: { abs($0.0 - item.0) < abs($1.0 - item.0) }),
       let im = NSImage(contentsOfFile: dir + "/" + best.1) {
        im.draw(in: NSRect(x: x, y: y + pad, width: w, height: h))
    }
    let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .bold)]
    (String(format: "%.2f s", item.0) as NSString).draw(at: NSPoint(x: x + 4, y: y + 18), withAttributes: attrs)
    (item.1 as NSString).draw(at: NSPoint(x: x + 4, y: y + 3), withAttributes: attrs)
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("ok \(out)")
