import AudioToolbox
import CoreAudio
import Foundation
import os

/// Plays the ultrasonic pilot tone(s) on one explicitly chosen output device (the built-in speakers),
/// independent of the system default output. Uses its own AUHAL unit.
public final class PilotPlayer: @unchecked Sendable {
    public let device: AudioDevice
    public let sampleRate: Double
    public let channels: Int

    private struct Shared: Sendable {
        var tones = ToneSet.silent
        var amplitude: Float = 0
        var running = false
        var silent = true   // reported back by the render thread
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let synth: PilotSynth
    private var unit: AudioUnit?
    private var started = false

    public init(device: AudioDevice) throws {
        guard device.outputChannels > 0 else { throw CoreAudioError(-1, "\(device.name) has no output channels") }
        self.device = device
        self.sampleRate = AudioDevices.nominalSampleRate(device.id) ?? device.nominalSampleRate
        self.channels = device.outputChannels
        self.synth = PilotSynth(sampleRate: sampleRate)
    }

    deinit {
        if let unit { AUHAL.dispose(unit) }
    }

    /// Starts the output unit. Tones fade in over 50 ms.
    public func start(tones: [PilotTone], amplitude: Float) throws {
        shared.withLock {
            $0.tones = ToneSet(tones)
            $0.amplitude = amplitude
            $0.running = true
        }
        guard !started else { return }

        let unit = try AUHAL.make()
        do {
            var deviceID = device.id
            try check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)),
                "set output device \(device.name)")
            try AUHAL.set(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                AUHAL.floatFormat(sampleRate: sampleRate, channels: channels), "output stream format")

            var callback = AURenderCallbackStruct(
                inputProc: { refCon, _, _, _, frames, ioData in
                    let player = Unmanaged<PilotPlayer>.fromOpaque(refCon).takeUnretainedValue()
                    return player.render(frames: Int(frames), ioData: ioData)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(
                AudioUnitSetProperty(
                    unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                    &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "set render callback")

            try check(AudioUnitInitialize(unit), "AudioUnitInitialize(output)")
            try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart(output)")
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.unit = unit
        started = true
    }

    /// Changes the tones. The current tones fade out, then the new ones fade in (no clicks).
    public func setTones(_ tones: [PilotTone]) {
        shared.withLock { $0.tones = ToneSet(tones) }
    }

    /// Linear output amplitude (1.0 = full scale), smoothed on the audio thread.
    public func setAmplitude(_ amplitude: Float) {
        shared.withLock { $0.amplitude = amplitude }
    }

    public var isSilent: Bool { shared.withLock { $0.silent } }

    /// Fades out (50 ms), then stops the output unit. Blocks for up to ~0.3 s.
    public func stop() {
        guard started, let unit else { return }
        shared.withLock { $0.running = false }
        let deadline = Date().addingTimeInterval(0.3)
        while !isSilent && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        // One more IO cycle so the final silent buffer reaches the speakers.
        Thread.sleep(forTimeInterval: 0.02)
        AUHAL.dispose(unit)
        self.unit = nil
        started = false
    }

    /// Waits until the current fade/transition has finished (envelope fully open or closed).
    public func waitForFade() {
        Thread.sleep(forTimeInterval: synth.fadeSeconds * 2 + 0.03)
    }

    // MARK: Render thread

    private func render(frames: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let silentNow = synth.isSilent
        // Never block the audio thread: if the main thread holds the lock, reuse the last parameters.
        if let p = shared.withLockIfAvailable({ s -> (ToneSet, Float, Bool) in
            s.silent = silentNow
            return (s.tones, s.amplitude, s.running)
        }) {
            synth.update(tones: p.0, amplitude: p.1, running: p.2)
        }

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        synth.render(left: left, right: right, frames: frames)
        if buffers.count > 2 {
            for i in 2..<buffers.count {
                if let data = buffers[i].mData { memset(data, 0, Int(buffers[i].mDataByteSize)) }
            }
        }
        return noErr
    }
}
