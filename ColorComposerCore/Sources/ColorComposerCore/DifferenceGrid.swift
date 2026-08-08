import Foundation

/// A rectangular grid of signed per-cell differences (`source − predicted`),
/// used by the source-vs-prediction comparison view.
///
/// Unlike `BrightnessGrid` (which is normalized to `0.0 ... 1.0`), a
/// `DifferenceGrid` holds signed values, roughly in `−1 ... 1`:
/// - **Positive** — the source is brighter than the achievable prediction, so
///   the palette *under-shoots* that cell.
/// - **Negative** — the palette *over-shoots* (the selected color is brighter
///   than the source target).
/// - **Zero** — exact match.
public struct DifferenceGrid: Sendable, Equatable {
    public let width: Int
    public let height: Int

    /// Row-major signed differences, length `width * height`, indexed as
    /// `y * width + x`.
    public let values: [Double]

    public init(width: Int, height: Int, values: [Double]) {
        precondition(width > 0 && height > 0, "DifferenceGrid dimensions must be positive")
        precondition(
            values.count == width * height,
            "values count (\(values.count)) must equal width*height (\(width * height))"
        )
        self.width = width
        self.height = height
        self.values = values
    }

    public func value(x: Int, y: Int) -> Double {
        values[y * width + x]
    }
}
