import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Raw capture from one explicitly chosen input device (the built-in mic) via its own AUHAL unit.
/// AUHAL does no voice processing, AGC or noise suppression (unlike kAudioUnitSubType_VoiceProcessingIO).
/// Every hardware channel is captured.
public final class MicCapture: @unchecked Sendable {
    public let device: AudioDevice
    public let sampleRate: Double
    public let channels: Int
    public let ring: AudioRingBuffer

    private static let maxFramesPerSlice = 4096
    private var unit: AudioUnit?
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private let channelBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    public init(device: AudioDevice, ringSeconds: Double = 2) throws {
        guard device.inputChannels > 0 else { throw CoreAudioError(-1, "\(device.name) has no input channels") }
        self.device = device
        self.sampleRate = AudioDevices.nominalSampleRate(device.id) ?? device.nominalSampleRate
        self.channels = device.inputChannels
        self.ring = AudioRingBuffer(channels: channels, minimumCapacity: Int(sampleRate * ringSeconds))

        bufferList = AudioBufferList.allocate(maximumBuffers: channels)
        channelBuffers = .allocate(capacity: channels)
        for ch in 0..<channels {
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxFramesPerSlice)
            buf.initialize(repeating: 0, count: Self.maxFramesPerSlice)
            channelBuffers[ch] = buf
            bufferList[ch] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(Self.maxFramesPerSlice * 4), mData: buf)
        }
    }

    deinit {
        if let unit { AUHAL.dispose(unit) }
        for ch in 0..<channels { channelBuffers[ch].deallocate() }
        channelBuffers.deallocate()
        free(bufferList.unsafeMutablePointer)
    }

    public static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Asks for microphone access if it hasn't been decided yet. Returns whether access is granted.
    public static func requestPermission() async -> Bool {
        switch permission {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public var isRunning: Bool { unit != nil }

    public func start() throws {
        guard unit == nil else { return }
        let unit = try AUHAL.make()
        do {
            // Input on element 1, no output on element 0.
            try AUHAL.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "EnableIO input")
            try AUHAL.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "EnableIO output")
            var deviceID = device.id
            try check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                    &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)),
                "set input device \(device.name)")
            // AUHAL does not resample input, so the client format must match the device rate.
            try AUHAL.set(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                AUHAL.floatFormat(sampleRate: sampleRate, channels: channels), "input client format")
            try AUHAL.set(
                unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                UInt32(Self.maxFramesPerSlice), "MaximumFramesPerSlice")

            var callback = AURenderCallbackStruct(
                inputProc: { refCon, flags, timeStamp, bus, frames, _ in
                    let capture = Unmanaged<MicCapture>.fromOpaque(refCon).takeUnretainedValue()
                    return capture.handleInput(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(
                AudioUnitSetProperty(
                    unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                    &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                "set input callback")

            self.unit = unit
            try check(AudioUnitInitialize(unit), "AudioUnitInitialize(input)")
            try check(AudioOutputUnitStart(unit), "AudioOutputUnitStart(input)")
        } catch {
            self.unit = nil
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    public func stop() {
        guard let unit else { return }
        AUHAL.dispose(unit)
        self.unit = nil
    }

    // MARK: Input thread (real-time safe)

    private func handleInput(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit, Int(frames) <= Self.maxFramesPerSlice else { return noErr }
        for ch in 0..<channels {
            bufferList[ch].mData = UnsafeMutableRawPointer(channelBuffers[ch])
            bufferList[ch].mDataByteSize = frames * 4
        }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }
        ring.write(channelBuffers, frames: Int(frames))
        return noErr
    }
}
