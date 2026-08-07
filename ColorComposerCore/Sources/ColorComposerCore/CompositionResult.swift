import Foundation

/// The outcome of solving a composition: for every logical output cell, the
/// selected palette color (by index) and its minimum weighted squared error.
public struct CompositionResult: Sendable {
    public let gridWidth: Int
    public let gridHeight: Int
    public let palette: [PaletteColor]
    public let weights: ChannelWeights

    /// Index into `palette` for each cell (row-major), or `nil` when no eligible
    /// candidate existed for that cell.
    public let colorIndices: [Int?]

    /// Minimum weighted squared error per cell (row-major). Cells with no
    /// eligible candidate use `Double.infinity`.
    public let errors: [Double]

    /// Number of palette colors that were excluded entirely (missing a required
    /// measurement) — useful diagnostics.
    public let excludedCandidateCount: Int

    public init(
        gridWidth: Int,
        gridHeight: Int,
        palette: [PaletteColor],
        weights: ChannelWeights,
        colorIndices: [Int?],
        errors: [Double],
        excludedCandidateCount: Int
    ) {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.palette = palette
        self.weights = weights
        self.colorIndices = colorIndices
        self.errors = errors
        self.excludedCandidateCount = excludedCandidateCount
    }

    public var cellCount: Int { gridWidth * gridHeight }

    public func colorIndex(x: Int, y: Int) -> Int? {
        colorIndices[y * gridWidth + x]
    }

    public func error(x: Int, y: Int) -> Double {
        errors[y * gridWidth + x]
    }

    /// Number of cells that could not be matched to any eligible color.
    public var unmatchedCellCount: Int {
        colorIndices.lazy.filter { $0 == nil }.count
    }
}
