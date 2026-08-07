import Foundation

/// Aggregate error statistics over a composition's matched cells.
public struct ErrorStatistics: Sendable, Equatable {
    public let mean: Double
    public let median: Double
    public let maximum: Double
    public let minimum: Double
    public let matchedCellCount: Int

    /// Builds statistics from a composition result, ignoring unmatched cells.
    public init(result: CompositionResult) {
        let finite = result.errors.filter { $0.isFinite }
        matchedCellCount = finite.count

        guard !finite.isEmpty else {
            mean = 0
            median = 0
            maximum = 0
            minimum = 0
            return
        }

        let sorted = finite.sorted()
        maximum = sorted.last ?? 0
        minimum = sorted.first ?? 0
        mean = finite.reduce(0, +) / Double(finite.count)
        median = Self.percentile(sorted, at: 0.5)
    }

    /// Fraction of matched cells whose error is strictly less than `threshold`.
    public func fractionBelow(threshold: Double, result: CompositionResult) -> Double {
        let finite = result.errors.filter { $0.isFinite }
        guard !finite.isEmpty else { return 0 }
        let below = finite.filter { $0 < threshold }.count
        return Double(below) / Double(finite.count)
    }

    private static func percentile(_ sorted: [Double], at q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let pos = (Double(sorted.count) - 1) * q
        let lower = Int(pos.rounded(.down))
        let upper = Int(pos.rounded(.up))
        if lower == upper { return sorted[lower] }
        let weight = pos - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }
}
