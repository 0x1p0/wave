import Foundation

/// Turns a stream of multichannel samples into overlapping analysis windows
/// (fftSize long, advancing by `hop`). Emits one window per hop once enough history exists.
public final class FrameSlicer {
    public let channels: Int
    public let fftSize: Int
    public let hop: Int

    // Per channel: [history (fftSize) | pending (hop)].
    private var buffers: [UnsafeMutablePointer<Float>]
    private var pending = 0
    private var filled = 0
    public private(set) var framesEmitted = 0

    public init(channels: Int, fftSize: Int = 4096, hop: Int = 512) {
        precondition(fftSize % hop == 0)
        self.channels = channels
        self.fftSize = fftSize
        self.hop = hop
        buffers = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: fftSize + hop)
            p.initialize(repeating: 0, count: fftSize + hop)
            return p
        }
    }

    deinit { buffers.forEach { $0.deallocate() } }

    /// Forgets all history (e.g. after the pilot changes), so the next window contains only new audio.
    public func reset() {
        pending = 0
        filled = 0
    }

    /// Feeds samples (one array per channel, equal lengths). Calls `onWindow` with one pointer per
    /// channel to fftSize contiguous samples (oldest first), valid only during the call.
    public func push(_ samples: [[Float]], onWindow: ([UnsafePointer<Float>]) -> Void) {
        guard samples.count == channels, let total = samples.first?.count, total > 0 else { return }
        var offset = 0
        while offset < total {
            let take = min(hop - pending, total - offset)
            for ch in 0..<channels {
                samples[ch].withUnsafeBufferPointer { src in
                    (buffers[ch] + fftSize + pending).update(from: src.baseAddress! + offset, count: take)
                }
            }
            pending += take
            offset += take
            if pending == hop {
                for ch in 0..<channels {
                    // Slide history left by one hop, appending the pending block.
                    memmove(buffers[ch], buffers[ch] + hop, fftSize * MemoryLayout<Float>.stride)
                }
                pending = 0
                filled = min(fftSize, filled + hop)
                if filled == fftSize {
                    framesEmitted += 1
                    onWindow(buffers.map { UnsafePointer($0) })
                }
            }
        }
    }
}
