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
    /// Loudness of the user's fist "snaps" (dB over the broadband baseline).
    public var grabPeaksDB: [Float]?
    /// Still-room micro-motion level (99.5th percentile; informational).
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
            parts.append(String(format: "grab snap ≥ %.1f dB (examples %.0f–%.0f)", i.grabSnapDB, g.min()!, g.max()!))
        }
        if layout.isStereo {
            parts.append(String(format: "swipe lag ≥ %.0f ms from %+.0f ms%@", fusion.minSwipeLag * 1000, fusion.lagCenter * 1000,
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

    /// Permissive grab settings for collecting examples (dial off; softer snaps count so the profile can set the line).
    public static func collectionInteraction(microNoiseDB: Float = 0) -> InteractionConfig {
        var c = InteractionConfig()
        c.dialEnabled = false
        c.grabEnabled = true
        c.grabSnapDB = 9
        c.grabCooldown = 1.5
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
            // Where a straight push lands (the two output paths differ a little), then how far swipes go from it.
            if pushLags.count >= 2 {
                f.lagCenter = Double(Stats.median(pushLags.map(Float.init)))
            } else if !leftLags.isEmpty && !rightLags.isEmpty {
                f.lagCenter = (Double(Stats.median(leftLags.map(Float.init))) + Double(Stats.median(rightLags.map(Float.init)))) / 2
            }
            let c = f.lagCenter
            if !leftLags.isEmpty && !rightLags.isEmpty {
                f.invertSwipeDirection = Stats.median(rightLags.map(Float.init)) < Stats.median(leftLags.map(Float.init))
            } else if !rightLags.isEmpty {
                f.invertSwipeDirection = Double(Stats.median(rightLags.map(Float.init))) < c
            } else if !leftLags.isEmpty {
                f.invertSwipeDirection = Double(Stats.median(leftLags.map(Float.init))) > c
            }
            let pushMax = pushLags.map { abs($0 - c) }.max()
            let swipeMin = (leftLags + rightLags).map { abs($0 - c) }.min()
            if let p = pushMax, let s = swipeMin, s > p {
                f.minSwipeLag = max(0.015, (p + s) / 2)
            } else if let p = pushMax {
                f.minSwipeLag = min(0.12, max(0.02, p + 0.015))
            }
        }

        var profile = CalibrationProfile(layout: layout, detector: d, fusion: f, noiseDB: noise)
        let microNoise = microLevel(quiet)
        profile.microNoiseDB = microNoise
        let grabPeaks = grabs.compactMap(\.microPeakDB)
        if !grabPeaks.isEmpty {
            var i = InteractionConfig()
            i.grabSnapDB = min(16, max(10, referenceNoise + 6, 0.6 * Stats.median(grabPeaks)))
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
