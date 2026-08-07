import Foundation

/// A rectangular grid of normalized brightness values in `0.0 ... 1.0`.
///
/// Represents one source image already mapped into the common logical output
/// coordinate system (scaled, and inverted if requested). The solver consumes
/// one grid per active lighting condition.
public struct BrightnessGrid: Sendable, Equatable {
    public let width: Int
    public let height: Int

    /// Row-major brightness values, length `width * height`, indexed as
    /// `y * width + x`.
    public private(set) var values: [Double]

    public init(width: Int, height: Int, values: [Double]) {
        precondition(width > 0 && height > 0, "BrightnessGrid dimensions must be positive")
        precondition(
            values.count == width * height,
            "values count (\(values.count)) must equal width*height (\(width * height))"
        )
        self.width = width
        self.height = height
        self.values = values
    }

    /// A constant-fill grid.
    public init(width: Int, height: Int, fill: Double) {
        self.init(width: width, height: height, values: Array(repeating: fill, count: width * height))
    }

    public func value(x: Int, y: Int) -> Double {
        values[y * width + x]
    }

    mutating func setValue(_ value: Double, x: Int, y: Int) {
        values[y * width + x] = value
    }

    /// Returns a grid with every brightness inverted (`1 - v`).
    public func inverted() -> BrightnessGrid {
        BrightnessGrid(width: width, height: height, values: values.map { 1.0 - $0 })
    }
}
