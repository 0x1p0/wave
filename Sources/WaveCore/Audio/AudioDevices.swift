import AudioToolbox
import CoreAudio
import Foundation

/// Snapshot of a Core Audio device.
public struct AudioDevice: Sendable, Hashable, CustomStringConvertible {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    public let manufacturer: String
    public let transportType: UInt32
    public let inputChannels: Int
    public let outputChannels: Int
    public let nominalSampleRate: Double
    public let availableSampleRates: [ClosedRange<Double>]
    public let inputDataSource: UInt32?
    public let outputDataSource: UInt32?

    public var isBuiltIn: Bool { transportType == kAudioDeviceTransportTypeBuiltIn }

    /// The 3.5 mm jack shows up as separate devices ("External Headphones", "External Microphone")
    /// that *also* report transport = built-in on Apple Silicon, so they must be excluded by name.
    public var isHeadphoneJack: Bool {
        let jackSources: Set<UInt32> = [fourCC("hdpn"), fourCC("extm"), fourCC("emic")]
        if let s = outputDataSource, jackSources.contains(s) { return true }
        if let s = inputDataSource, jackSources.contains(s) { return true }
        return uid.localizedCaseInsensitiveContains("Headphone")
            || uid.localizedCaseInsensitiveContains("Headset")
            || name.hasPrefix("External")
    }

    public var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity"
        case 0: return "unknown"
        default: return fourCCString(transportType)
        }
    }

    public var sampleRatesDescription: String {
        availableSampleRates.map { r in
            r.lowerBound == r.upperBound ? "\(Int(r.lowerBound))" : "\(Int(r.lowerBound))–\(Int(r.upperBound))"
        }.joined(separator: ", ")
    }

    public var description: String { "\(name) [\(uid)]" }
}

/// Explicit Core Audio device discovery. Wave never relies on the system default devices.
public enum AudioDevices {
    public static func all() -> [AudioDevice] {
        let ids = CAProperty.array(
            AudioObjectID(kAudioObjectSystemObject),
            CAProperty.address(kAudioHardwarePropertyDevices),
            zero: AudioObjectID(0))
        return ids.compactMap(device(id:))
    }

    public static func device(id: AudioObjectID) -> AudioDevice? {
        guard let uid = CAProperty.string(id, CAProperty.address(kAudioDevicePropertyDeviceUID)) else { return nil }
        let name = CAProperty.string(id, CAProperty.address(kAudioObjectPropertyName)) ?? "?"
        let manufacturer = CAProperty.string(id, CAProperty.address(kAudioObjectPropertyManufacturer)) ?? "?"
        let transport = CAProperty.value(id, CAProperty.address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0
        let rate = CAProperty.value(id, CAProperty.address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0)) ?? 0
        let ranges = CAProperty.array(
            id, CAProperty.address(kAudioDevicePropertyAvailableNominalSampleRates),
            zero: AudioValueRange(mMinimum: 0, mMaximum: 0)
        ).map { $0.mMinimum...$0.mMaximum }
        let inCh = CAProperty.channelCount(id, scope: kAudioObjectPropertyScopeInput)
        let outCh = CAProperty.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
        let inSource = inCh > 0
            ? CAProperty.value(id, CAProperty.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeInput), initial: UInt32(0))
            : nil
        let outSource = outCh > 0
            ? CAProperty.value(id, CAProperty.address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput), initial: UInt32(0))
            : nil
        return AudioDevice(
            id: id, uid: uid, name: name, manufacturer: manufacturer, transportType: transport,
            inputChannels: inCh, outputChannels: outCh, nominalSampleRate: rate,
            availableSampleRates: ranges, inputDataSource: inSource, outputDataSource: outSource)
    }

    /// The MacBook's own speakers (never the headphone jack, Bluetooth or a virtual device).
    public static func builtInSpeakers() -> AudioDevice? {
        let candidates = all().filter { $0.isBuiltIn && $0.outputChannels > 0 && !$0.isHeadphoneJack }
        return candidates.first { $0.outputDataSource == fourCC("ispk") }
            ?? candidates.first { $0.uid.localizedCaseInsensitiveContains("Speaker") }
            ?? candidates.first { $0.name.localizedCaseInsensitiveContains("Speaker") }
            ?? candidates.first
    }

    /// The MacBook's own microphone array (never a headset or external mic).
    public static func builtInMicrophone() -> AudioDevice? {
        let candidates = all().filter { $0.isBuiltIn && $0.inputChannels > 0 && !$0.isHeadphoneJack }
        return candidates.first { $0.inputDataSource == fourCC("imic") }
            ?? candidates.first { $0.uid.localizedCaseInsensitiveContains("Microphone") }
            ?? candidates.first { $0.name.localizedCaseInsensitiveContains("Microphone") }
            ?? candidates.first
    }

    public static func defaultOutputID() -> AudioObjectID? {
        CAProperty.value(
            AudioObjectID(kAudioObjectSystemObject),
            CAProperty.address(kAudioHardwarePropertyDefaultOutputDevice), initial: AudioObjectID(0))
    }

    public static func defaultInputID() -> AudioObjectID? {
        CAProperty.value(
            AudioObjectID(kAudioObjectSystemObject),
            CAProperty.address(kAudioHardwarePropertyDefaultInputDevice), initial: AudioObjectID(0))
    }

    public static func isAlive(_ id: AudioObjectID) -> Bool {
        (CAProperty.value(id, CAProperty.address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) ?? 0) != 0
    }

    // MARK: Volume / mute

    /// The volume slider value (0…1) the menu bar shows for this device, if it has one.
    public static func volumeScalar(_ id: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Float? {
        if scope == kAudioObjectPropertyScopeOutput,
           let v = CAProperty.value(
               id, CAProperty.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope), initial: Float32(0)) {
            return v
        }
        if let v = CAProperty.value(id, CAProperty.address(kAudioDevicePropertyVolumeScalar, scope), initial: Float32(0)) {
            return v
        }
        let channels = CAProperty.channelCount(id, scope: scope)
        let perChannel = (1...max(1, channels)).compactMap {
            CAProperty.value(id, CAProperty.address(kAudioDevicePropertyVolumeScalar, scope, UInt32($0)), initial: Float32(0))
        }
        return perChannel.isEmpty ? nil : perChannel.reduce(0, +) / Float(perChannel.count)
    }

    /// Hardware gain in dB for the current volume setting (0 dB = full volume), if the device reports it.
    public static func volumeDecibels(_ id: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Float? {
        if let v = CAProperty.value(id, CAProperty.address(kAudioDevicePropertyVolumeDecibels, scope), initial: Float32(0)) {
            return v
        }
        let channels = CAProperty.channelCount(id, scope: scope)
        let perChannel = (1...max(1, channels)).compactMap {
            CAProperty.value(id, CAProperty.address(kAudioDevicePropertyVolumeDecibels, scope, UInt32($0)), initial: Float32(0))
        }
        return perChannel.isEmpty ? nil : perChannel.reduce(0, +) / Float(perChannel.count)
    }

    public static func isMuted(_ id: AudioObjectID, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> Bool? {
        if let m = CAProperty.value(id, CAProperty.address(kAudioDevicePropertyMute, scope), initial: UInt32(0)) {
            return m != 0
        }
        if let m = CAProperty.value(id, CAProperty.address(kAudioDevicePropertyMute, scope, 1), initial: UInt32(0)) {
            return m != 0
        }
        return nil
    }

    /// Sets the device's own volume slider (0…1). Only for explicit user requests: the Wave app never
    /// changes system volume by itself.
    public static func setVolumeScalar(_ id: AudioObjectID, _ value: Float, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) throws {
        let v = Float32(min(1, max(0, value)))
        let candidates = [
            CAProperty.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope),
            CAProperty.address(kAudioDevicePropertyVolumeScalar, scope),
        ]
        if let addr = candidates.first(where: { CAProperty.isSettable(id, $0) }) {
            try CAProperty.setValue(id, addr, v)
            return
        }
        let channels = (1...max(1, CAProperty.channelCount(id, scope: scope)))
            .map { CAProperty.address(kAudioDevicePropertyVolumeScalar, scope, UInt32($0)) }
            .filter { CAProperty.isSettable(id, $0) }
        guard !channels.isEmpty else { throw CoreAudioError(-1, "this device's volume is not settable") }
        for addr in channels { try CAProperty.setValue(id, addr, v) }
    }

    public static func setMuted(_ id: AudioObjectID, _ muted: Bool, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) throws {
        let value = UInt32(muted ? 1 : 0)
        let main = CAProperty.address(kAudioDevicePropertyMute, scope)
        if CAProperty.isSettable(id, main) {
            try CAProperty.setValue(id, main, value)
            return
        }
        let channels = (1...max(1, CAProperty.channelCount(id, scope: scope)))
            .map { CAProperty.address(kAudioDevicePropertyMute, scope, UInt32($0)) }
            .filter { CAProperty.isSettable(id, $0) }
        guard !channels.isEmpty else { throw CoreAudioError(-1, "this device's mute is not settable") }
        for addr in channels { try CAProperty.setValue(id, addr, value) }
    }

    // MARK: Sample rate

    /// Changes a device's nominal sample rate. This is system-wide (affects other apps using the device),
    /// so Wave only does it when explicitly asked.
    public static func setNominalSampleRate(_ id: AudioObjectID, _ rate: Double) throws {
        try CAProperty.setValue(id, CAProperty.address(kAudioDevicePropertyNominalSampleRate), Float64(rate))
        // The change is asynchronous; wait briefly for it to take effect.
        for _ in 0..<50 {
            if let current = CAProperty.value(
                id, CAProperty.address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0)),
               abs(current - rate) < 0.5 { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    public static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
        CAProperty.value(id, CAProperty.address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
    }
}
