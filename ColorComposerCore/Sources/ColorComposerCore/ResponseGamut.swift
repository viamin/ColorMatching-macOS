import Foundation

/// One eligible palette color reduced to the analyzed conditions — a single
/// polyline in a parallel-coordinates plot.
public struct GamutVector: Sendable, Equatable, Identifiable {
    public let id: Int
    public let name: String?
    public let rgb: RGBColor

    /// Normalized brightness per analyzed condition, in `conditions` order.
    public let brightness: [Double]

    public init(id: Int, name: String?, rgb: RGBColor, brightness: [Double]) {
        self.id = id
        self.name = name
        self.rgb = rgb
        self.brightness = brightness
    }
}

/// A group of target vectors that quantize to the same cell of response space.
///
/// Clustering keeps the view legible and the reachability search cheap: a
/// 500×500 composition asks for 250 000 target vectors but only a few thousand
/// distinct ones.
public struct TargetCluster: Sendable, Equatable, Identifiable {
    /// Bin-center brightness per analyzed condition, in `conditions` order.
    public let brightness: [Double]

    /// How many output cells landed in this cluster.
    public let cellCount: Int

    /// Lowest weighted squared error any eligible color achieves against this
    /// target, or `.infinity` when no color is eligible at all.
    public let nearestError: Double

    public var id: [Double] { brightness }

    public init(brightness: [Double], cellCount: Int, nearestError: Double) {
        self.brightness = brightness
        self.cellCount = cellCount
        self.nearestError = nearestError
    }
}

/// The achievable response vectors of the loaded colors, the distribution of
/// targets the source images ask for, and where the two fail to overlap.
///
/// Reachability is deliberately *not* baked in: each cluster carries its
/// nearest achievable error so a caller can move the "close enough" cutoff
/// without re-running the analysis.
public struct ResponseGamut: Sendable, Equatable {
    /// Weighted-squared-error cutoff below which a target counts as matchable.
    /// Roughly 0.1 brightness error on a single unit-weighted channel.
    public static let defaultReachabilityThreshold = 0.01

    /// Analyzed conditions in canonical order — the plot's axes.
    public let conditions: [LightingCondition]

    /// One vector per color measured for every analyzed condition.
    public let vectors: [GamutVector]

    /// Quantized target distribution, empty when there are no source grids.
    public let clusters: [TargetCluster]

    /// Colors dropped for missing a measurement on an analyzed condition.
    public let excludedColorCount: Int

    /// Per-axis palette reach versus target demand.
    public let coverage: [AxisCoverage]

    public init(
        conditions: [LightingCondition],
        vectors: [GamutVector],
        clusters: [TargetCluster],
        excludedColorCount: Int
    ) {
        self.conditions = conditions
        self.vectors = vectors
        self.clusters = clusters
        self.excludedColorCount = excludedColorCount
        self.coverage = Self.makeCoverage(conditions: conditions, vectors: vectors, clusters: clusters)
    }

    /// `true` when there is nothing to plot.
    public var isEmpty: Bool { vectors.isEmpty && clusters.isEmpty }

    /// Total output cells represented by `clusters`.
    public var targetCellCount: Int {
        clusters.reduce(0) { $0 + $1.cellCount }
    }

    /// Targets no eligible color matches within `threshold`.
    public func unreachableClusters(threshold: Double = defaultReachabilityThreshold) -> [TargetCluster] {
        clusters.filter { $0.nearestError > threshold }
    }

    /// Output cells whose target is unreachable within `threshold`.
    public func unreachableCellCount(threshold: Double = defaultReachabilityThreshold) -> Int {
        unreachableClusters(threshold: threshold).reduce(0) { $0 + $1.cellCount }
    }

    /// Share of output cells whose target is unreachable within `threshold`.
    public func unreachableFraction(threshold: Double = defaultReachabilityThreshold) -> Double {
        let total = targetCellCount
        guard total > 0 else { return 0 }
        return Double(unreachableCellCount(threshold: threshold)) / Double(total)
    }

    /// Axes where the palette cannot span the targets, worst shortfall first —
    /// the most actionable guidance for what color to measure or buy next.
    public var gaps: [AxisCoverage] {
        coverage.filter { !$0.isCovered }
            .sorted { max($0.shortfallAbove, $0.shortfallBelow) > max($1.shortfallAbove, $1.shortfallBelow) }
    }

    private static func makeCoverage(
        conditions: [LightingCondition],
        vectors: [GamutVector],
        clusters: [TargetCluster]
    ) -> [AxisCoverage] {
        conditions.indices.map { axis in
            AxisCoverage(
                condition: conditions[axis],
                palette: GamutSpan(vectors.map { $0.brightness[axis] }),
                target: GamutSpan(clusters.map { $0.brightness[axis] })
            )
        }
    }
}
