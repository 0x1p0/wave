import CoreGraphics
import Foundation
import WaveCore

/// The last few seconds of frames for the debug views: feature traces plus a spectrogram pixel buffer.
/// Main-actor only; not observed directly (DebugModel bumps `revision` when it changes).
@MainActor
public final class FeatureHistory {
    public let capacity: Int
    public private(set) var count = 0
    private var head = 0  // next write index

    public private(set) var times: [Double]
    public private(set) var toward: [Float]
    public private(set) var away: [Float]
    public private(set) var reference: [Float]
    public private(set) var velocity: [Float]
    public private(set) var pilot: [Float]

    // Spectrogram: one column per frame, rows = bands × (2·halfWidth + 1), highest frequency at the top.
    public private(set) var rows = 0
    public private(set) var halfWidth = 64
    public private(set) var bandCount = 1
    private var pixels: [UInt8] = []
    private var floorDB: Float?
    public var rangeDB: Float = 50

    public init(capacity: Int = 640) {
        self.capacity = capacity
        times = Array(repeating: 0, count: capacity)
        toward = Array(repeating: 0, count: capacity)
        away = Array(repeating: 0, count: capacity)
        reference = Array(repeating: 0, count: capacity)
        velocity = Array(repeating: 0, count: capacity)
        pilot = Array(repeating: -120, count: capacity)
    }

    public func clear() {
        count = 0
        head = 0
        floorDB = nil
        pixels = Array(repeating: 0, count: pixels.count)
    }

    /// Index (oldest = 0) → ring index.
    @inline(__always) public func ring(_ i: Int) -> Int { (head - count + i + capacity) % capacity }

    public var newestTime: Double? { count > 0 ? times[ring(count - 1)] : nil }

    public func append(_ frame: PipelineFrame, halfWidth: Int, bandCount: Int) {
        guard let f = frame.bands.first else { return }
        let idx = head
        times[idx] = frame.time
        toward[idx] = f.towardDB
        away[idx] = f.awayDB
        reference[idx] = f.referenceDB
        velocity[idx] = f.velocity
        pilot[idx] = f.pilotDB
        if !frame.display.isEmpty { writeColumn(frame.display, at: idx, halfWidth: halfWidth, bandCount: bandCount) }
        head = (head + 1) % capacity
        count = min(capacity, count + 1)
    }

    private func writeColumn(_ column: [Float], at idx: Int, halfWidth: Int, bandCount: Int) {
        let newRows = column.count
        if newRows != rows || halfWidth != self.halfWidth || bandCount != self.bandCount {
            rows = newRows
            self.halfWidth = halfWidth
            self.bandCount = bandCount
            pixels = Array(repeating: 0, count: rows * capacity * 4)
            floorDB = nil
        }
        // Auto floor: 25th percentile of this column (pilot rows excluded), smoothed.
        let span = 2 * halfWidth + 1
        var values: [Float] = []
        values.reserveCapacity(column.count)
        for (i, v) in column.enumerated() where abs(i % span - halfWidth) > 2 { values.append(v) }
        values.sort()
        let p25 = values.isEmpty ? -120 : values[values.count / 4]
        floorDB = floorDB.map { $0 + (p25 - $0) * 0.05 } ?? p25
        let floor = floorDB! - 3

        for b in 0..<bandCount {
            for k in 0..<span {
                let v = column[b * span + k]
                let row = b * span + (span - 1 - k)  // highest frequency at the top
                let t = max(0, min(1, (v - floor) / rangeDB))
                let c = Colormap.inferno[Int(pow(t, 0.8) * 255)]
                let p = (row * capacity + idx) * 4
                pixels[p] = c.0; pixels[p + 1] = c.1; pixels[p + 2] = c.2; pixels[p + 3] = 255
            }
        }
    }

    /// The spectrogram in time order (oldest column left; unfilled columns black). Two memcpys per row.
    public func spectrogramImage() -> CGImage? {
        guard rows > 0 else { return nil }
        let rowBytes = capacity * 4
        var ordered = Data(count: rows * rowBytes)
        let empty = capacity - count
        let oldest = ring(0)
        let firstRun = min(count, capacity - oldest)  // oldest … end of ring
        let secondRun = count - firstRun               // wrapped part
        ordered.withUnsafeMutableBytes { dst in
            pixels.withUnsafeBytes { src in
                for r in 0..<rows {
                    let rowSrc = src.baseAddress! + r * rowBytes
                    let rowDst = dst.baseAddress! + r * rowBytes + empty * 4
                    memcpy(rowDst, rowSrc + oldest * 4, firstRun * 4)
                    if secondRun > 0 { memcpy(rowDst + firstRun * 4, rowSrc, secondRun * 4) }
                }
            }
        }
        guard let provider = CGDataProvider(data: ordered as CFData) else { return nil }
        return CGImage(
            width: capacity, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

enum Colormap {
    /// Approximation of matplotlib's "inferno" (black → purple → orange → pale yellow).
    static let inferno: [(UInt8, UInt8, UInt8)] = {
        let stops: [(Float, Float, Float, Float)] = [
            (0.00, 0, 0, 4), (0.15, 31, 12, 72), (0.30, 85, 15, 109), (0.45, 136, 34, 106),
            (0.60, 186, 54, 85), (0.72, 227, 89, 51), (0.85, 249, 140, 10), (1.00, 252, 255, 164),
        ]
        return (0..<256).map { i in
            let t = Float(i) / 255
            let j = stops.lastIndex { $0.0 <= t } ?? 0
            let a = stops[j], b = stops[min(j + 1, stops.count - 1)]
            let u = b.0 > a.0 ? (t - a.0) / (b.0 - a.0) : 0
            func mix(_ x: Float, _ y: Float) -> UInt8 { UInt8(max(0, min(255, x + (y - x) * u))) }
            return (mix(a.1, b.1), mix(a.2, b.2), mix(a.3, b.3))
        }
    }()
}
