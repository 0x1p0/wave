import AppKit
import AVFoundation
import Foundation

/// `wave-probe frames VIDEO --at 1.2,3.4[,…] [--out DIR] [--width PX]`: stills from a session's webcam video
/// at given times (seconds), to see what the hand did when a detection went right or wrong.
enum FramesCommand {
    static func run(video: URL, times: [Double], out: URL, width: Int) async throws -> Int32 {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: width, height: width)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        for t in times {
            let (image, actual) = try await generator.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600))
            // Mirror horizontally so it matches what the user saw (left is left).
            let mirrored = mirror(image) ?? image
            let rep = NSBitmapImageRep(cgImage: mirrored)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = out.appendingPathComponent(String(format: "frame-%06.2f.png", t))
            try png.write(to: url)
            print(String(format: "%7.2f s (actual %.2f) → %@", t, actual.seconds, url.path))
        }
        return 0
    }

    private static func mirror(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(image.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
