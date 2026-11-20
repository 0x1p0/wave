import Foundation

/// Per-user detector thresholds measured by the guided calibration (M4).
public struct CalibrationProfile: Codable, Sendable, Equatable {
    public var created = Date()
    public var layout: PilotLayout
    public var detector: DetectorConfig
    public var fusion: FusionConfig
    /// Still-scene sideband level (99.5th percentile, dB over baseline).
    public var noiseDB: Float
    public var pushPeaksDB: [Float] = []
    public var pushDurations: [Double] = []
    public var pushLags: [Double] = []
    public var swipeLeftLags: [Double] = []
    public var swipeRightLags: [Double] = []
    /// Hold/dial/grab thresholds (nil in profiles from before grab support).
    public var interaction: InteractionConfig?
    public var grabPeaksDB: [Float]?
    /// Still-room micro-motion level (99.5th percentile).
    public var microNoiseDB: Float?

    public init(layout: PilotLayout, detector: DetectorConfig, fusion: FusionConfig, noiseDB: Float) {
        self.layout = layout
        self.detector = detector
        self.fusion = fusion
        self.noiseDB = noiseDB
    }

    public var summary: String {
        var parts = [String(format: "still noise %.1f dB", noiseDB)]
        if !pushPeaksDB.isEmpty { parts.append(String(format: "push peaks %.0f–%.0f dB", pushPeaksDB.min()!, pushPeaksDB.max()!)) }
        parts.append(String(format: "start ≥ %.1f dB, peak ≥ %.1f dB, %.2f–%.2f s",
                            detector.onThresholdDB, detector.minPeakDB, detector.minDuration, detector.maxDuration))
        if let g = grabPeaksDB, !g.isEmpty, let i = interaction {
            parts.append(String(format: "grab ≥ %.1f dB (examples %.0f–%.0f)", i.grabMicroDB, g.min()!, g.max()!))
        }
        if layout.isStereo {
            parts.append(String(format: "swipe lag ≥ %.0f ms%@", fusion.minSwipeLag * 1000,
                                fusion.invertSwipeDirection ? ", direction flipped" : ""))
        }
        return parts.joined(separator: " · ")
    }
}

/// Turns a still-scene recording plus example gestures into thresholds.
public enum Calibrator {
    /// 99.5th percentile of the stronger sideband over all bands — what "nothing happening" looks like.
    public static func noiseLevel(_ frames: [PipelineFrame]) -> Float {
        Stats.percentile(frames.flatMap { $0.bands.map { max($0.towardDB, $0.awayDB) } }, 0.995)
    }

    public static func microLevel(_ frames: [PipelineFrame]) -> Float {
        Stats.percentile(frames.flatMap { $0.bands.map(\.microDB) }, 0.995)
    }

    /// Permissive grab settings for collecting examples (dial off so every burst is judged as a grab).
    public static func collectionInteraction(microNoiseDB: Float) -> InteractionConfig {
        var c = InteractionConfig()
        c.dialEnabled = false
        c.grabEnabled = true
        c.grabMicroDB = max(5, microNoiseDB + 3)
        c.grabRiseDB = 5
        c.grabMaxDuration = 0.8
        c.grabMaxDisplacement = 0.03
        c.grabMaxNetSpeed = 0.05
        c.targetCycle = 6  // stay ready while the user gets ready to close the hand
        return c
    }

    public static func referenceLevel(_ frames: [PipelineFrame]) -> Float {
        Stats.percentile(frames.flatMap { $0.bands.map(\.referenceDB) }, 0.995)
    }

    /// Permissive settings used while collecting example gestures: anything clearly above the still-scene
    /// noise with a toward→away shape counts.
    public static func collectionDetector(noiseDB: Float) -> DetectorConfig {
        var c = DetectorConfig()
        c.sensitivity = 0.5
        c.onThresholdDB = max(4, noiseDB + 1.5)
        c.offThresholdDB = max(2, c.onThresholdDB - 4)
        c.minPeakDB = c.onThresholdDB + 1
        c.minDuration = 0.12
        c.maxDuration = 1.2
        c.maxReversalGap = 0.35
        return c
    }

    public static func collectionFusion() -> FusionConfig {
        var f = FusionConfig()
        f.maxPairGap = 0.7
        return f
    }

    public static func makeProfile(
        layout: PilotLayout, quiet: [PipelineFrame], pushes: [GestureEvent],
        swipesLeft: [GestureEvent] = [], swipesRight: [GestureEvent] = [], grabs: [GestureEvent] = []
    ) -> CalibrationProfile {
        let noise = noiseLevel(quiet)
        let referenceNoise = referenceLevel(quiet)
        var d = DetectorConfig()
        let gestures = pushes + swipesLeft + swipesRight
        let peaks = gestures.map { min($0.towardPeakDB, $0.awayPeakDB) }
        if let low = peaks.min() {
            let typical = Stats.median(peaks)
            d.onThresholdDB = min(14, max(4, max(noise + 2, 0.45 * typical)))
            d.offThresholdDB = max(2, d.onThresholdDB - 4)
            d.minPeakDB = min(22, max(d.onThresholdDB + 1, noise + 3, min(low - 2, 0.75 * typical)))
        } else {
            d.onThresholdDB = max(d.onThresholdDB, noise + 2)
            d.offThresholdDB = max(2, d.onThresholdDB - 4)
            d.minPeakDB = max(d.minPeakDB, d.onThresholdDB + 2)
        }
        let durations = gestures.map(\.duration)
        if let shortest = durations.min(), let longest = durations.max() {
            d.minDuration = max(0.12, min(0.2, 0.7 * shortest))
            d.maxDuration = min(1.2, max(0.6, 1.3 * longest))
        }
        d.referenceRejectDB = max(5, referenceNoise + 3)

        var f = FusionConfig()
        let pushLags = pushes.compactMap(\.lag)
        let leftLags = swipesLeft.compactMap(\.lag)
        let rightLags = swipesRight.compactMap(\.lag)
        if layout.isStereo {
            // Fusion calls lag > 0 (left side first) "swipe right". If the user's right swipes came out
            // with smaller lags than their left swipes, the geometry is mirrored: flip.
            if !leftLags.isEmpty && !rightLags.isEmpty {
                f.invertSwipeDirection = Stats.median(rightLags.map(Float.init)) < Stats.median(leftLags.map(Float.init))
            } else if !rightLags.isEmpty {
                f.invertSwipeDirection = Stats.median(rightLags.map(Float.init)) < 0
            } else if !leftLags.isEmpty {
                f.invertSwipeDirection = Stats.median(leftLags.map(Float.init)) > 0
            }
            let pushMax = pushLags.map(abs).max()
            let swipeMin = (leftLags + rightLags).map(abs).min()
            if let p = pushMax, let s = swipeMin, s > p {
                f.minSwipeLag = (p + s) / 2
            } else if let p = pushMax {
                f.minSwipeLag = min(0.12, max(0.03, p + 0.02))
            }
        }

        var profile = CalibrationProfile(layout: layout, detector: d, fusion: f, noiseDB: noise)
        let microNoise = microLevel(quiet)
        profile.microNoiseDB = microNoise
        let grabPeaks = grabs.compactMap(\.microPeakDB)
        if !grabPeaks.isEmpty {
            var i = InteractionConfig()
            i.grabMicroDB = min(25, max(microNoise + 4, 0.6 * Stats.median(grabPeaks), 6))
            i.grabRiseDB = min(i.grabRiseDB, max(5, 0.5 * (Stats.median(grabPeaks) - microNoise)))
            profile.interaction = i
            profile.grabPeaksDB = grabPeaks
        }
        profile.pushPeaksDB = pushes.map { min($0.towardPeakDB, $0.awayPeakDB) }
        profile.pushDurations = pushes.map(\.duration)
        profile.pushLags = pushLags
        profile.swipeLeftLags = leftLags
        profile.swipeRightLags = rightLags
        return profile
    }
}
