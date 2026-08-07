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
/// The default and only v1 implementation is `WeightedSquaredErrorScorer`.
/// Alternative strategies (cosine similarity, perceptual distance, future
/// dithering/diffusion hooks) can be added by conforming to this protocol and
/// passing the new scorer to `CompositionSolver`.
public protocol CompositionScorer: Sendable {
    func score(
        candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> ScorerResult
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
