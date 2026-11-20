import AVFoundation
import Foundation
import WaveCore
import WaveRT

struct Interrupted: Error {}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Built-in speakers → pilot, built-in mic → ring buffer → sliding FFT. Runs synchronously on the
/// calling thread (polling the lock-free ring buffer), which keeps the probe simple and deterministic.
final class ProbeEngine {
    let speakers: AudioDevice
    let mic: AudioDevice
    let pilot: PilotPlayer
    let capture: MicCapture
    let analyzer: SpectrumAnalyzer
    let slicer: FrameSlicer
    let hop: Int
    var amplitude: Float
    private(set) var spectrum = [Float]()
    private(set) var peakSample: Float = 0
    private var restoreMicRate: Double?

    var sampleRate: Double { capture.sampleRate }

    /// FFT size and hop scale with the sample rate so 96 kHz keeps the same ~11.7 Hz / ~10.7 ms resolution.
    init(amplitudeDB: Double, micRate: Double? = nil, overrides: DeviceOverrides = .init()) throws {
        let speakers = try overrides.speakers()
        var mic = try overrides.microphone()
        if let micRate, abs(micRate - mic.nominalSampleRate) > 0.5 {
            guard mic.availableSampleRates.contains(where: { $0.contains(micRate) }) else {
                throw ProbeError("\(mic.name) does not support \(Int(micRate)) Hz (supports \(mic.sampleRatesDescription)).")
            }
            restoreMicRate = mic.nominalSampleRate
            try AudioDevices.setNominalSampleRate(mic.id, micRate)
            mic = AudioDevices.device(id: mic.id) ?? mic
        }
        self.speakers = speakers
        self.mic = mic
        self.amplitude = Float(pow(10, amplitudeDB / 20))
        pilot = try PilotPlayer(device: speakers)
        capture = try MicCapture(device: mic)
        let fftSize = capture.sampleRate > 60_000 ? 8192 : 4096
        let hop = fftSize / 8
        self.hop = hop
        analyzer = SpectrumAnalyzer(fftSize: fftSize, sampleRate: capture.sampleRate)
        slicer = FrameSlicer(channels: capture.channels, fftSize: fftSize, hop: hop)
    }

    func start(tones: [PilotTone]) throws {
        try capture.start()
        try pilot.start(tones: tones, amplitude: amplitude)
    }

    /// Fades the pilot out, then stops everything and restores any sample-rate change.
    func shutdown() {
        pilot.stop()
        capture.stop()
        if let restoreMicRate {
            try? AudioDevices.setNominalSampleRate(mic.id, restoreMicRate)
            self.restoreMicRate = nil
        }
    }

    func setTones(_ tones: [PilotTone]) { pilot.setTones(tones) }

    func band(_ hz: Double) -> PilotBand { PilotBand(pilotHz: hz, binWidth: analyzer.binWidth) }

    func frames(forSeconds seconds: Double) -> Int { max(1, Int(seconds * sampleRate / Double(hop))) }

    /// Waits for transitions to finish, then discards buffered audio and window history.
    func settle(_ seconds: Double) throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if wave_stop_requested() { throw Interrupted() }
            Thread.sleep(forTimeInterval: 0.01)
        }
        capture.ring.skipToLatest()
        slicer.reset()
    }

    /// Runs the analysis until `frames` spectra have been produced; `handler` sees each (mean across mic channels).
    func collect(frames: Int, _ handler: ([Float]) -> Void) throws {
        var produced = 0
        var lastAudio = Date()
        while produced < frames {
            if wave_stop_requested() { throw Interrupted() }
            Thread.sleep(forTimeInterval: 0.005)
            let samples = capture.ring.readAvailable()
            guard let n = samples.first?.count, n > 0 else {
                if Date().timeIntervalSince(lastAudio) > 2 {
                    throw ProbeError("No audio is arriving from \(mic.name).")
                }
                continue
            }
            lastAudio = Date()
            for ch in samples { for s in ch { peakSample = max(peakSample, abs(s)) } }
            slicer.push(samples) { windows in
                guard produced < frames else { return }
                analyzer.averagePowerSpectrum(windows, into: &spectrum)
                produced += 1
                handler(spectrum)
            }
        }
    }

    /// True if everything captured so far was exactly zero (typical when mic access is denied).
    var heardDigitalSilence: Bool { peakSample == 0 }

    func resetPeak() { peakSample = 0 }
}

/// Debug-only device overrides (by Core Audio UID). Default: built-in speakers and mic.
struct DeviceOverrides {
    var outputUID: String?
    var inputUID: String?

    var isActive: Bool { outputUID != nil || inputUID != nil }

    func speakers() throws -> AudioDevice {
        if let uid = outputUID {
            guard let d = AudioDevices.all().first(where: { $0.uid == uid && $0.outputChannels > 0 }) else {
                throw ProbeError("No output device with UID '\(uid)' (see `wave-probe devices`).")
            }
            return d
        }
        guard let d = AudioDevices.builtInSpeakers() else {
            throw ProbeError("No built-in speakers found (is this a MacBook?).")
        }
        return d
    }

    func microphone() throws -> AudioDevice {
        if let uid = inputUID {
            guard let d = AudioDevices.all().first(where: { $0.uid == uid && $0.inputChannels > 0 }) else {
                throw ProbeError("No input device with UID '\(uid)' (see `wave-probe devices`).")
            }
            return d
        }
        guard let d = AudioDevices.builtInMicrophone() else {
            throw ProbeError("No built-in microphone found (is this a MacBook?).")
        }
        return d
    }
}

// MARK: - Environment checks shared by the commands

enum Environment {
    static func micModeName() -> String {
        switch AVCaptureDevice.activeMicrophoneMode {
        case .standard: return "Standard"
        case .wideSpectrum: return "Wide Spectrum"
        case .voiceIsolation: return "Voice Isolation"
        @unknown default: return "unknown"
        }
    }

    static func permissionName(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "granted"
        case .denied: return "DENIED"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }

    /// Speaker volume line plus a fatal error if the speakers can't produce the pilot.
    static func speakerState(_ speakers: AudioDevice) -> (summary: String, fatal: String?, warning: String?) {
        let vol = AudioDevices.volumeScalar(speakers.id)
        let db = AudioDevices.volumeDecibels(speakers.id)
        let muted = AudioDevices.isMuted(speakers.id) ?? false
        var summary = vol.map { "volume \(Int(($0 * 100).rounded()))%" } ?? "volume unknown"
        if let db { summary += String(format: " (%.1f dB)", db) }
        if muted { summary += ", MUTED" }
        let howTo = """
            Control Center → Sound → choose "\(speakers.name)", adjust, then switch back to your \
            headphones/AirPods if you like (each device remembers its own volume).
            """
        if muted { return (summary, "\(speakers.name) are muted, so the pilot can't play. Unmute them: \(howTo)", nil) }
        if let vol, vol < 0.2 {
            return (summary, nil, "Speaker volume is low (\(Int(vol * 100))%). For the probe set it to ~50%: \(howTo)")
        }
        return (summary, nil, nil)
    }
}

// MARK: - Terminal helpers

enum Term {
    static var isTTY: Bool { isatty(STDOUT_FILENO) != 0 }

    static var columns: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
        if let c = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(c) { return n }
        return 120
    }

    static let reset = "\u{1B}[0m"
    static func bold(_ s: String) -> String { isTTY ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
    static func dim(_ s: String) -> String { isTTY ? "\u{1B}[2m\(s)\u{1B}[0m" : s }

    /// Heat palette (xterm-256): black → blue → cyan → green → yellow → red → white.
    static let heat: [Int] = [16, 17, 18, 19, 20, 21, 27, 33, 39, 45, 51, 50, 49, 48, 47, 46,
                              82, 118, 154, 190, 226, 220, 214, 208, 202, 196, 197, 198, 199, 200, 201, 231]
    static let ascii = Array(" .:-=+*#%@")

    static func cell(_ t: Double, ascii useASCII: Bool) -> String {
        let x = min(1, max(0, t))
        if useASCII {
            return String(ascii[Int(x * Double(ascii.count - 1))])
        }
        return "\u{1B}[48;5;\(heat[Int(x * Double(heat.count - 1))])m \u{1B}[0m"
    }

    /// Writes through stdio (same buffer as `print`) and flushes, so ordering is preserved when piped.
    static func write(_ s: String) {
        fputs(s, stdout)
        fflush(stdout)
    }
}

func pad(_ s: String, _ width: Int, right: Bool = true) -> String {
    if s.count >= width { return s }
    let fill = String(repeating: " ", count: width - s.count)
    return right ? fill + s : s + fill
}

func fmt(_ v: Double, _ decimals: Int = 1, sign: Bool = false) -> String {
    String(format: sign ? "%+.\(decimals)f" : "%.\(decimals)f", v)
}

func fmt(_ v: Float, _ decimals: Int = 1, sign: Bool = false) -> String { fmt(Double(v), decimals, sign: sign) }
