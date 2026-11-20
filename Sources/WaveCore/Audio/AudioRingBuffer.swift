import Foundation
import WaveRT

/// Lock-free single-producer / single-consumer multichannel float ring buffer.
/// The producer is the audio input thread; the consumer is the analysis thread.
public final class AudioRingBuffer: @unchecked Sendable {
    public let channels: Int
    public let capacity: Int            // frames, power of two
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>   // channel-major: [ch * capacity + i]
    private let writeIndex: UnsafeMutablePointer<Int64> // total frames ever written (atomic)
    private var readIndex: Int64 = 0                    // consumer-only
    public private(set) var droppedFrames: Int64 = 0    // consumer-only (overruns)

    public init(channels: Int, minimumCapacity: Int) {
        var cap = 1
        while cap < minimumCapacity { cap <<= 1 }
        self.channels = channels
        self.capacity = cap
        self.mask = cap - 1
        storage = .allocate(capacity: channels * cap)
        storage.initialize(repeating: 0, count: channels * cap)
        writeIndex = .allocate(capacity: 1)
        writeIndex.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        writeIndex.deallocate()
    }

    // MARK: Producer (real-time safe: no locks, no allocation)

    public func write(_ source: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        let w = Int(wave_atomic_load_acquire(writeIndex))
        for ch in 0..<channels {
            let src = source[ch]
            let base = storage + ch * capacity
            let start = w & mask
            let first = min(frames, capacity - start)
            (base + start).update(from: src, count: first)
            if first < frames { base.update(from: src + first, count: frames - first) }
        }
        wave_atomic_store_release(writeIndex, Int64(w + frames))
    }

    // MARK: Consumer

    public var totalFramesWritten: Int64 { wave_atomic_load_acquire(writeIndex) }

    /// Discards everything buffered so far.
    public func skipToLatest() {
        readIndex = wave_atomic_load_acquire(writeIndex)
    }

    /// Returns all frames available since the last read, one array per channel.
    public func readAvailable() -> [[Float]] {
        let w = wave_atomic_load_acquire(writeIndex)
        if w - readIndex > Int64(capacity) {
            // Overrun: the consumer fell behind by more than the buffer; jump ahead.
            droppedFrames += w - readIndex - Int64(capacity / 2)
            readIndex = w - Int64(capacity / 2)
        }
        let count = Int(w - readIndex)
        guard count > 0 else { return Array(repeating: [], count: channels) }
        let start = Int(readIndex) & mask
        let first = min(count, capacity - start)
        var out: [[Float]] = (0..<channels).map { ch in
            let base = storage + ch * capacity
            return [Float](unsafeUninitializedCapacity: count) { buf, initialized in
                buf.baseAddress!.update(from: base + start, count: first)
                if first < count { (buf.baseAddress! + first).update(from: base, count: count - first) }
                initialized = count
            }
        }
        // If the producer lapped us while copying, the oldest frames may be torn: drop them.
        let after = wave_atomic_load_acquire(writeIndex)
        let torn = Int(max(0, after - Int64(capacity) - readIndex))
        if torn > 0 {
            out = out.map { Array($0.dropFirst(min(torn, $0.count))) }
            droppedFrames += Int64(torn)
        }
        readIndex = w
        return out
    }
}
