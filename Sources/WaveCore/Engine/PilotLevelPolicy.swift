import Foundation

/// Keeps the pilot's *acoustic* level constant as the speakers' own volume changes.
///
/// The system volume scales whatever Wave plays. M0 found −8 dBFS at a speaker gain of −18.6 dB (50 %)
/// works well, so Wave aims for the same total (digital level + hardware gain) and makes up the
/// difference digitally, within limits. When it can't, it pauses rather than playing too quietly.
public struct PilotLevelPolicy: Sendable, Codable, Equatable {
    public var referenceAmplitudeDBFS: Double = -8
    public var referenceSpeakerGainDB: Double = -18.6
    /// Never drive the pilot hotter than this (headroom against clipping/distortion).
    public var maxAmplitudeDBFS: Double = -2

    public enum Decision: Sendable, Equatable {
        case play(amplitudeDBFS: Double)
        case muted
        case volumeTooLow(neededDBFS: Double)

        public var amplitudeDBFS: Double? {
            if case .play(let a) = self { return a }
            return nil
        }

        public var pauseReason: String? {
            switch self {
            case .play: return nil
            case .muted: return "Built-in speakers are muted"
            case .volumeTooLow: return "Volume too low for Wave"
            }
        }
    }

    public init() {}

    public func decide(speakerGainDB: Double?, muted: Bool) -> Decision {
        if muted { return .muted }
        guard let gain = speakerGainDB else { return .play(amplitudeDBFS: referenceAmplitudeDBFS) }
        let needed = referenceAmplitudeDBFS + (referenceSpeakerGainDB - gain)
        if needed > maxAmplitudeDBFS + 0.5 { return .volumeTooLow(neededDBFS: needed) }
        return .play(amplitudeDBFS: min(needed, maxAmplitudeDBFS))
    }

    /// Lowest speaker gain (dB) at which Wave can still compensate.
    public var minimumSpeakerGainDB: Double { referenceSpeakerGainDB - (maxAmplitudeDBFS - referenceAmplitudeDBFS) - 0.5 }
}
