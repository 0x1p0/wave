import Foundation
import WaveCore

/// A small text log of what Wave detected and did — never audio — for troubleshooting a gesture that went
/// wrong after the fact: ~/Library/Application Support/Wave/detections.log. Kept under ~1 MB.
@MainActor
final class DetectionLog {
    static let shared = DetectionLog()

    let url: URL
    private var handle: FileHandle?
    private let clock: DateFormatter

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wave", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("detections.log")
        clock = DateFormatter()
        clock.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        trim()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        let text = clock.string(from: Date()) + "  " + line + "\n"
        try? handle?.write(contentsOf: Data(text.utf8))
    }

    /// Keeps the newest half once the file passes 1 MB.
    private func trim() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000,
              let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(500_000)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[(newline + 1)...] }
        try? Data(tail).write(to: url)
    }
}
