import Foundation

/// How a source image is mapped into the common output coordinate system when
/// its aspect ratio differs from the output.
public enum ImageScalingMode: String, Sendable, Codable, CaseIterable {
    /// Entire image visible, centered, uniform scale (letterboxed).
    case fit
    /// Image fills the output, centered, uniform scale (cropped to fit).
    case fill
    /// Image stretched non-uniformly to exactly cover the output.
    case stretch
}

/// Per-channel weights for the weighted squared-error scorer.
///
/// Conditions with weight `0` (or absent) are ignored by the scorer. Conditions
/// with weight `> 0` are *required*: a palette color missing any of them is
/// excluded from matching.
public struct ChannelWeights: Sendable, Codable, Equatable {
    public var white: Double
    public var red: Double
    public var green: Double
    public var blue: Double
    public var lps: Double

    public init(white: Double = 0, red: Double = 0, green: Double = 0, blue: Double = 0, lps: Double = 0) {
        self.white = white
        self.red = red
        self.green = green
        self.blue = blue
        self.lps = lps
    }

    public func weight(for condition: LightingCondition) -> Double {
        switch condition {
        case .white: return white
        case .red: return red
        case .green: return green
        case .blue: return blue
        case .lps: return lps
        }
    }

    /// Conditions that influence matching (weight greater than zero).
    public var activeConditions: [LightingCondition] {
        LightingCondition.all.filter { weight(for: $0) > 0 }
    }

    /// A flat `(condition, weight)` list for active conditions in canonical order.
    public var activeEntries: [(condition: LightingCondition, weight: Double)] {
        LightingCondition.all.compactMap { condition in
            let w = weight(for: condition)
            return w > 0 ? (condition, w) : nil
        }
    }
}
