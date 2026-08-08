import Foundation

/// A target brightness vector assembled from source-image pixels at one output
/// location, keyed by lighting condition.
///
/// Conditions without a source image are absent (treated as missing), matching
/// the `color_matching` target-vector semantics.
public struct TargetResponseVector: Sendable, Equatable {
    public var brightness: [LightingCondition: Double]

    public init(_ brightness: [LightingCondition: Double]) {
        self.brightness = brightness
    }

    public func value(for condition: LightingCondition) -> Double? {
        brightness[condition]
    }
}

/// Outcome of scoring one candidate against a target. Lower scores are better.
public enum ScorerResult: Sendable, Equatable {
    /// A finite score; the candidate is rankable.
    case score(Double)
    /// The candidate cannot be ranked under the current policy (for example,
    /// it is missing a measurement for a required condition).
    case excluded
}

/// Pluggable matching algorithm.
///
/// Implementations: `WeightedSquaredErrorScorer` (v1 default),
/// `WorstCaseChannelScorer`, and `PerceptualScorer`.
/// Alternative strategies can be added by conforming to this protocol and
/// passing the new scorer to `CompositionSolver`.
public protocol CompositionScorer: Sendable {
    func score(
        candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> ScorerResult
}

/// Identifies which scoring algorithm to use. Serializable for project
/// persistence and `CaseIterable` for UI pickers.
public enum ScorerKind: String, Sendable, Codable, CaseIterable {
    /// Mean weighted squared error per channel (v1 default).
    case weightedSquaredError
    /// Minimizes the worst-case per-channel squared error so no single channel
    /// is silently sacrificed for a better average.
    case worstCaseChannel
    /// Weights channels by CIE photopic luminosity sensitivity instead of raw
    /// user sliders.
    case perceptual

    public var displayName: String {
        switch self {
        case .weightedSquaredError: return "Weighted Squared Error"
        case .worstCaseChannel: return "Worst-Case Channel"
        case .perceptual: return "Perceptual"
        }
    }

    public func makeScorer() -> any CompositionScorer {
        switch self {
        case .weightedSquaredError: return WeightedSquaredErrorScorer()
        case .worstCaseChannel: return WorstCaseChannelScorer()
        case .perceptual: return PerceptualScorer()
        }
    }
}

/// Weighted squared-error illuminant scoring — the v1 default.
///
/// For each condition with weight `> 0`, accumulates
/// `weight * (candidate.brightness - target.brightness)^2`. A candidate is
/// `excluded` when it (or the target) is missing a measurement for any
/// condition with weight greater than zero, so a missing measurement is never
/// confused with zero brightness.
///
/// This mirrors `ColorMatching.WeightedSquaredError` in the Elixir service so
/// the client and server agree on selection.
public struct WeightedSquaredErrorScorer: CompositionScorer {
    public init() {}

    public func score(
        candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> ScorerResult {
        let active = weights.activeEntries

        // Exclusion: any required condition missing on candidate or target.
        for (condition, weight) in active {
            guard weight > 0,
                  candidate.brightness(for: condition) != nil,
                  target.value(for: condition) != nil
            else {
                return .excluded
            }
        }

        var sum = 0.0
        for (condition, weight) in active {
            let c = candidate.brightness(for: condition) ?? 0
            let t = target.value(for: condition) ?? 0
            let diff = c - t
            sum += diff * diff * weight
        }
        return .score(sum)
    }
}

/// Worst-case-channel scorer.
///
/// Returns the maximum weighted squared error across all active channels so
/// that no single channel is silently sacrificed for a better average. A
/// candidate is `excluded` under the same conditions as
/// `WeightedSquaredErrorScorer` — missing any required measurement.
public struct WorstCaseChannelScorer: CompositionScorer {
    public init() {}

    public func score(
        candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> ScorerResult {
        let active = weights.activeEntries

        for (condition, weight) in active {
            guard weight > 0,
                  candidate.brightness(for: condition) != nil,
                  target.value(for: condition) != nil
            else {
                return .excluded
            }
        }

        var worst = 0.0
        for (condition, weight) in active {
            let c = candidate.brightness(for: condition) ?? 0
            let t = target.value(for: condition) ?? 0
            let diff = c - t
            let channelError = diff * diff * weight
            if channelError > worst { worst = channelError }
        }
        return .score(worst)
    }
}

/// Perceptual scorer.
///
/// Uses fixed CIE photopic luminosity sensitivity weights per channel rather
/// than the raw user sliders, so the score reflects how humans perceive
/// brightness differences under each light color. User weights still control
/// which channels are *required* (any weight `> 0` makes that condition
/// required), but the numerical contribution of each channel to the score is
/// set by perception, not the slider value.
///
/// Sensitivity coefficients (normalized to white = 1):
/// - White:  1.0000
/// - Green:  0.7152  (CIE 1931 peak-sensitivity channel)
/// - Red:    0.2126
/// - LPS:    0.5893  (sodium yellow ~589 nm, interpolated from CIE curve)
/// - Blue:   0.0722
public struct PerceptualScorer: CompositionScorer {
    /// CIE photopic luminosity weight per lighting condition, normalized to
    /// white = 1. Used in place of the user slider values.
    static let perceptualWeight: [LightingCondition: Double] = [
        .white: 1.0000,
        .green: 0.7152,
        .red:   0.2126,
        .lps:   0.5893,
        .blue:  0.0722
    ]

    public init() {}

    public func score(
        candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> ScorerResult {
        let active = weights.activeEntries

        for (condition, weight) in active {
            guard weight > 0,
                  candidate.brightness(for: condition) != nil,
                  target.value(for: condition) != nil
            else {
                return .excluded
            }
        }

        var sum = 0.0
        for (condition, _) in active {
            let c = candidate.brightness(for: condition) ?? 0
            let t = target.value(for: condition) ?? 0
            let diff = c - t
            let w = Self.perceptualWeight[condition] ?? 1.0
            sum += diff * diff * w
        }
        return .score(sum)
    }
}
