import Foundation

/// The closed interval covered by a set of brightness values on one axis.
public struct GamutSpan: Sendable, Equatable {
    public let lowest: Double
    public let highest: Double

    public init(lowest: Double, highest: Double) {
        self.lowest = lowest
        self.highest = highest
    }

    /// `nil` for an empty sample — an axis with no colors or no targets has no
    /// span, which is distinct from a span of zero width.
    public init?(_ values: [Double]) {
        guard let lowest = values.min(), let highest = values.max() else { return nil }
        self.init(lowest: lowest, highest: highest)
    }
}

/// What the palette can reach versus what the source images demand, along one
/// lighting condition's axis.
///
/// This is the root-cause layer of the gamut view: a target vector can be
/// unreachable simply because no loaded color is bright (or dark) enough under
/// a single condition, and that is worth saying in words rather than leaving it
/// to be inferred from an error map.
public struct AxisCoverage: Sendable, Equatable {
    public let condition: LightingCondition

    /// Brightness span of the eligible colors, or `nil` when none are eligible.
    public let palette: GamutSpan?

    /// Brightness span demanded by the source images, or `nil` without targets.
    public let target: GamutSpan?

    public init(condition: LightingCondition, palette: GamutSpan?, target: GamutSpan?) {
        self.condition = condition
        self.palette = palette
        self.target = target
    }

    /// How far the brightest target overshoots the brightest available color.
    public var shortfallAbove: Double {
        guard let palette, let target else { return 0 }
        return max(0, target.highest - palette.highest)
    }

    /// How far the darkest target undershoots the darkest available color.
    public var shortfallBelow: Double {
        guard let palette, let target else { return 0 }
        return max(0, palette.lowest - target.lowest)
    }

    /// `true` when the palette spans every target demanded on this axis.
    public var isCovered: Bool { shortfallAbove == 0 && shortfallBelow == 0 }

    /// Plain-language explanation of the gap, or `nil` when the axis is covered.
    public var gapSummary: String? {
        let clauses = [brightnessClause, darknessClause].compactMap { $0 }
        return clauses.isEmpty ? nil : clauses.joined(separator: " ")
    }

    private var brightnessClause: String? {
        guard shortfallAbove > 0, let palette, let target else { return nil }
        return "No color is bright enough under \(condition.displayName) — targets reach "
            + "\(Self.format(target.highest)) but the palette tops out at \(Self.format(palette.highest))."
    }

    private var darknessClause: String? {
        guard shortfallBelow > 0, let palette, let target else { return nil }
        return "No color is dark enough under \(condition.displayName) — targets go down to "
            + "\(Self.format(target.lowest)) but the palette bottoms out at \(Self.format(palette.lowest))."
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
