public enum RasterMode: String, Sendable, Codable, CaseIterable {
    case flat
    case halftone
    case twoColor

    public var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .halftone: return "Halftone"
        case .twoColor: return "Two-color"
        }
    }
}

/// A raw RGBA8 raster buffer (row-major, 4 bytes per pixel, unpremultiplied).
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

public extension BrightnessGrid {
    /// Nearest-neighbor upsample by an integer block factor (each cell becomes a
    /// `factor × factor` block). Used to render the logical solution to a larger
    /// export/print raster without introducing new colors.
    func upsampled(by factor: Int) -> BrightnessGrid {
        guard factor > 1 else { return self }
        let outW = width * factor
        let outH = height * factor
        var out = [Double](repeating: 0, count: outW * outH)
        for y in 0..<height {
            for x in 0..<width {
                let v = values[y * width + x]
                for dy in 0..<factor {
                    for dx in 0..<factor {
                        out[(y * factor + dy) * outW + (x * factor + dx)] = v
                    }
                }
            }
        }
        return BrightnessGrid(width: outW, height: outH, values: out)
    }
}

/// Renders a solved composition into raster outputs:
/// the printable color composite, a normalized error map, and per-condition
/// predicted lighting previews.
public enum CompositionRenderer {
    private struct TwoColorCandidate {
        let color: PaletteColor
        let responses: [Double]
    }

    /// Precomputed per-pair terms for `bestTwoColorMix`. `differences`,
    /// `weightedDifferences`, `denominator`, and `offset` depend only on the
    /// pair's two candidate responses and the (fixed) channel weights, never
    /// on the cell being solved, so they are computed once per pair here
    /// instead of once per pair per cell.
    private struct TwoColorPair {
        let firstIndex: Int
        let secondIndex: Int
        let differences: [Double]
        let weightedDifferences: [Double]
        let denominator: Double
        let offset: Double
    }

    private struct TwoColorContext {
        let entries: [ChannelWeights.Entry]
        let candidates: [TwoColorCandidate]
        let pairs: [TwoColorPair]
    }

    public static func composite(
        _ result: CompositionResult,
        mode: RasterMode = .flat,
        pixelsPerCell: Int = 1
    ) -> RGBAImage {
        let factor = max(pixelsPerCell, 1)
        let outWidth = result.gridWidth * factor
        let outHeight = result.gridHeight * factor
        var rgba = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        let dotOrder = mode == .halftone ? dotPixelOrder(for: factor) : []
        let screenOrder = mode == .twoColor ? screenPixelOrder(for: factor) : []
        let twoColorContext = mode == .twoColor ? makeTwoColorContext(for: result) : nil

        for y in 0..<result.gridHeight {
            for x in 0..<result.gridWidth {
                let cell = y * result.gridWidth + x
                let positions: [(x: Int, y: Int, color: RGBColor?)]
                switch mode {
                case .flat:
                    positions = filledCell(for: result, cell: cell, factor: factor)
                case .halftone:
                    positions = halftoneCell(
                        for: result,
                        cell: cell,
                        factor: factor,
                        order: dotOrder
                    )
                case .twoColor:
                    positions = twoColorCell(
                        for: result,
                        cell: cell,
                        factor: factor,
                        order: screenOrder,
                        context: twoColorContext
                    )
                }
                for position in positions {
                    let output = ((y * factor + position.y) * outWidth + x * factor + position.x) * 4
                    guard let color = position.color else { continue }
                    rgba[output] = color.red
                    rgba[output + 1] = color.green
                    rgba[output + 2] = color.blue
                    rgba[output + 3] = 255
                }
            }
        }
        return RGBAImage(width: outWidth, height: outHeight, rgba: rgba)
    }

    private static func filledCell(
        for result: CompositionResult,
        cell: Int,
        factor: Int
    ) -> [(x: Int, y: Int, color: RGBColor?)] {
        let color = result.colorIndices[cell].map { result.palette[$0].rgb }
        return (0..<factor).flatMap { y in
            (0..<factor).map { x in (x: x, y: y, color: color) }
        }
    }

    private static func halftoneCell(
        for result: CompositionResult,
        cell: Int,
        factor: Int,
        order: [(x: Int, y: Int)]
    ) -> [(x: Int, y: Int, color: RGBColor?)] {
        guard let index = result.colorIndices[cell] else {
            return paperCell(factor: factor)
        }
        let coverage = targetBrightness(for: result, cell: cell)
        let dotCount = Int((coverage * Double(order.count)).rounded())
        let dotKeys = Set(order.prefix(dotCount).map { pixelKey(x: $0.x, y: $0.y, factor: factor) })
        let color = result.palette[index].rgb
        let paper = RGBColor(red: 255, green: 255, blue: 255)
        return (0..<factor).flatMap { y in
            (0..<factor).map { x in
                (x: x, y: y, color: dotKeys.contains(pixelKey(x: x, y: y, factor: factor)) ? color : paper)
            }
        }
    }

    private static func twoColorCell(
        for result: CompositionResult,
        cell: Int,
        factor: Int,
        order: [(x: Int, y: Int)],
        context: TwoColorContext?
    ) -> [(x: Int, y: Int, color: RGBColor?)] {
        guard let context, let mix = bestTwoColorMix(for: result, cell: cell, context: context) else {
            return filledCell(for: result, cell: cell, factor: factor)
        }
        let firstCount = Int((mix.fraction * Double(order.count)).rounded())
        let firstKeys = Set(order.prefix(firstCount).map { pixelKey(x: $0.x, y: $0.y, factor: factor) })
        return (0..<factor).flatMap { y in
            (0..<factor).map { x in
                let isFirst = firstKeys.contains(pixelKey(x: x, y: y, factor: factor))
                return (x: x, y: y, color: isFirst ? mix.first : mix.second)
            }
        }
    }

    private static func paperCell(factor: Int) -> [(x: Int, y: Int, color: RGBColor?)] {
        let paper = RGBColor(red: 255, green: 255, blue: 255)
        return (0..<factor).flatMap { y in
            (0..<factor).map { x in (x: x, y: y, color: paper) }
        }
    }

    private static func pixelKey(x: Int, y: Int, factor: Int) -> Int {
        y * factor + x
    }

    private static func targetBrightness(for result: CompositionResult, cell: Int) -> Double {
        let entries = result.weights.activeEntries
        let totalWeight = entries.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return 0 }
        let weighted = entries.reduce(0.0) { sum, entry in
            sum + (result.sourceGrids[entry.condition]?.values[cell] ?? 0) * entry.weight
        }
        return max(0, min(1, weighted / totalWeight))
    }

    private static func makeTwoColorContext(for result: CompositionResult) -> TwoColorContext {
        let entries = result.weights.activeEntries
        let conditions = entries.map(\.condition)
        let candidates = result.palette.compactMap { color in
            responseVector(for: color, conditions: conditions).map {
                TwoColorCandidate(color: color, responses: $0)
            }
        }
        let pairs = makeTwoColorPairs(entries: entries, candidates: candidates)
        return TwoColorContext(entries: entries, candidates: candidates, pairs: pairs)
    }

    private static func makeTwoColorPairs(
        entries: [ChannelWeights.Entry],
        candidates: [TwoColorCandidate]
    ) -> [TwoColorPair] {
        guard candidates.count > 1 else { return [] }
        var pairs: [TwoColorPair] = []
        for first in 0..<(candidates.count - 1) {
            for second in (first + 1)..<candidates.count {
                let a = candidates[first].responses
                let b = candidates[second].responses
                var differences = [Double](repeating: 0, count: entries.count)
                var weightedDifferences = [Double](repeating: 0, count: entries.count)
                var denominator = 0.0
                var offset = 0.0
                for channel in 0..<entries.count {
                    let difference = a[channel] - b[channel]
                    let weightedDifference = entries[channel].weight * difference
                    differences[channel] = difference
                    weightedDifferences[channel] = weightedDifference
                    denominator += weightedDifference * difference
                    offset += weightedDifference * b[channel]
                }
                pairs.append(TwoColorPair(
                    firstIndex: first,
                    secondIndex: second,
                    differences: differences,
                    weightedDifferences: weightedDifferences,
                    denominator: denominator,
                    offset: offset
                ))
            }
        }
        return pairs
    }

    private static func bestTwoColorMix(
        for result: CompositionResult,
        cell: Int,
        context: TwoColorContext
    ) -> (first: RGBColor, second: RGBColor, fraction: Double)? {
        let entries = context.entries
        let candidates = context.candidates
        guard candidates.count > 1 else {
            return candidates.first.map { (first: $0.color.rgb, second: $0.color.rgb, fraction: 1) }
        }
        let target = entries.map { result.sourceGrids[$0.condition]?.values[cell] ?? 0 }
        var best: (first: RGBColor, second: RGBColor, fraction: Double)?
        var bestError = Double.infinity

        for pair in context.pairs {
            var numerator = 0.0
            for channel in 0..<entries.count {
                numerator += pair.weightedDifferences[channel] * target[channel]
            }
            numerator -= pair.offset
            let fraction = pair.denominator > 0 ? max(0, min(1, numerator / pair.denominator)) : 0
            let b = candidates[pair.secondIndex].responses
            var error = 0.0
            for channel in 0..<entries.count {
                let prediction = b[channel] + fraction * pair.differences[channel]
                let difference = prediction - target[channel]
                error += entries[channel].weight * difference * difference
            }
            if error < bestError {
                bestError = error
                best = (
                    first: candidates[pair.firstIndex].color.rgb,
                    second: candidates[pair.secondIndex].color.rgb,
                    fraction: fraction
                )
            }
        }
        return best
    }

    private static func responseVector(
        for color: PaletteColor,
        conditions: [LightingCondition]
    ) -> [Double]? {
        let values = conditions.compactMap { color.brightness(for: $0) }
        return values.count == conditions.count ? values : nil
    }

    private static func dotPixelOrder(for factor: Int) -> [(x: Int, y: Int)] {
        let center = (Double(factor - 1) / 2, Double(factor - 1) / 2)
        return (0..<factor).flatMap { y in (0..<factor).map { x in (x: x, y: y) } }
            .sorted { left, right in
                let leftDistance = squaredDistance(from: left, to: center)
                let rightDistance = squaredDistance(from: right, to: center)
                if leftDistance == rightDistance {
                    if left.y != right.y { return left.y < right.y }
                    return left.x < right.x
                }
                return leftDistance < rightDistance
            }
    }

    private static func squaredDistance(
        from pixel: (x: Int, y: Int),
        to center: (Double, Double)
    ) -> Double {
        let dx = Double(pixel.x) - center.0
        let dy = Double(pixel.y) - center.1
        return dx * dx + dy * dy
    }

    private static func screenPixelOrder(for factor: Int) -> [(x: Int, y: Int)] {
        let matrix = [
            [0, 8, 2, 10],
            [12, 4, 14, 6],
            [3, 11, 1, 9],
            [15, 7, 13, 5]
        ]
        return (0..<factor).flatMap { y in (0..<factor).map { x in (x: x, y: y) } }
            .sorted { left, right in
                let leftRank = matrix[left.y % 4][left.x % 4]
                let rightRank = matrix[right.y % 4][right.x % 4]
                return leftRank == rightRank
                    ? (left.y, left.x) < (right.y, right.x)
                    : leftRank < rightRank
            }
    }

    /// On-screen composite preview with unmatched cells replaced by a visible
    /// magenta marker so missing measurements are never invisible.
    public static func compositePreview(
        _ result: CompositionResult,
        mode: RasterMode = .flat,
        pixelsPerCell: Int = 1
    ) -> RGBAImage {
        previewImage(composite(result, mode: mode, pixelsPerCell: pixelsPerCell), for: result, factor: pixelsPerCell)
    }

    /// Generic soft-proof preview of the printable composite. This is a
    /// lightweight approximation of how the palette may compress on paper, not
    /// an ICC-managed conversion. Cells that exceed the conservative printable
    /// envelope are flagged in `outOfGamutCells` and tinted with a warning wash.
    public static func softProof(
        _ result: CompositionResult,
        profile: SoftProofProfile = .genericPrinter,
        mode: RasterMode = .flat,
        pixelsPerCell: Int = 1
    ) -> SoftProofPreview {
        SoftProofing.preview(result, profile: profile, mode: mode, pixelsPerCell: pixelsPerCell)
    }

    /// On-screen soft-proof preview with the same unmatched-cell marker used by
    /// `compositePreview(_:)`, so proofing does not hide measurement gaps.
    public static func softProofPreview(
        _ result: CompositionResult,
        profile: SoftProofProfile = .genericPrinter,
        mode: RasterMode = .flat,
        pixelsPerCell: Int = 1
    ) -> SoftProofPreview {
        let preview = softProof(result, profile: profile, mode: mode, pixelsPerCell: pixelsPerCell)
        return SoftProofPreview(
            image: previewImage(preview.image, for: result, factor: pixelsPerCell),
            outOfGamutCells: preview.outOfGamutCells,
            outOfGamutCount: preview.outOfGamutCount
        )
    }

    /// Normalized error map. Brighter means larger matching error; unmatched
    /// cells are the brightest.
    public static func errorMap(_ result: CompositionResult) -> BrightnessGrid {
        let finite = result.errors.filter { $0.isFinite }
        let maxError = max(finite.max() ?? 0, 1e-9)

        let values = result.errors.map { error -> Double in
            guard error.isFinite else { return 1.0 }
            return min(error / maxError, 1.0)
        }
        return BrightnessGrid(width: result.gridWidth, height: result.gridHeight, values: values)
    }

    /// Predicted grayscale appearance under one lighting condition: each cell
    /// shows the selected palette color's measured brightness for that
    /// condition. Colors without that measurement render as black.
    public static func lightingPreview(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> BrightnessGrid {
        let values = (0..<result.cellCount).map { cell -> Double in
            guard let index = result.colorIndices[cell] else { return 0 }
            return result.palette[index].brightness(for: condition) ?? 0
        }
        return BrightnessGrid(width: result.gridWidth, height: result.gridHeight, values: values)
    }

    /// Predicted appearance under one lighting condition, tinted by the
    /// condition's representative color (`LightingCondition.displayTint`) so the
    /// preview reads like the image viewed under that colored light. Each cell
    /// maps from black to the tint by the selected color's measured brightness.
    public static func lightingPreviewTinted(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> RGBAImage {
        let tint = condition.displayTint
        var rgba = [UInt8](repeating: 0, count: result.cellCount * 4)

        for cell in 0..<result.cellCount {
            let base = cell * 4
            let brightness: Double
            if let index = result.colorIndices[cell] {
                brightness = result.palette[index].brightness(for: condition) ?? 0
            } else {
                brightness = 0
            }
            let scaled = max(0, min(1, brightness))
            rgba[base] = UInt8((scaled * tint.red) * 255)
            rgba[base + 1] = UInt8((scaled * tint.green) * 255)
            rgba[base + 2] = UInt8((scaled * tint.blue) * 255)
            rgba[base + 3] = 255
        }
        return RGBAImage(width: result.gridWidth, height: result.gridHeight, rgba: rgba)
    }

    /// Signed per-cell difference between the source brightness for a condition
    /// and the predicted brightness of the selected color: `source − predicted`.
    ///
    /// Positive values mean the palette under-shoots (source brighter than the
    /// achievable prediction); negative values mean it over-shoots. When no
    /// source grid exists for the condition the difference is `0` everywhere.
    public static func lightingDifference(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> DifferenceGrid {
        let predicted = lightingPreview(result, for: condition)
        guard let source = result.sourceGrids[condition] else {
            return DifferenceGrid(
                width: result.gridWidth,
                height: result.gridHeight,
                values: [Double](repeating: 0, count: result.cellCount)
            )
        }
        let values = (0..<result.cellCount).map { source.values[$0] - predicted.values[$0] }
        return DifferenceGrid(width: result.gridWidth, height: result.gridHeight, values: values)
    }

    /// The source-vs-prediction difference for one condition, rendered with a
    /// diverging colormap so the direction and magnitude of each cell's error
    /// are readable at a glance:
    /// - under-shoots (source brighter, positive difference) trend **blue**;
    /// - over-shoots (predicted brighter, negative difference) trend **red**;
    /// - near-zero stays dark.
    ///
    /// Cells with no selected color (unmatched) render as a neutral gray marker.
    public static func lightingDifferenceTinted(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> RGBAImage {
        let difference = lightingDifference(result, for: condition)
        var rgba = [UInt8](repeating: 0, count: result.cellCount * 4)
        for cell in 0..<result.cellCount {
            let base = cell * 4
            let rgb = divergingColor(for: difference.values[cell], matched: result.colorIndices[cell] != nil)
            rgba[base] = rgb.red
            rgba[base + 1] = rgb.green
            rgba[base + 2] = rgb.blue
            rgba[base + 3] = 255
        }
        return RGBAImage(width: result.gridWidth, height: result.gridHeight, rgba: rgba)
    }

    /// The source brightness grid for a condition, tinted by the condition's
    /// representative color — the counterpart to `lightingPreviewTinted`, so
    /// source and prediction render in the same style for side-by-side
    /// comparison. Returns transparent black when no source grid exists.
    public static func sourcePreviewTinted(
        _ result: CompositionResult,
        for condition: LightingCondition
    ) -> RGBAImage {
        guard let source = result.sourceGrids[condition] else {
            return RGBAImage(width: result.gridWidth, height: result.gridHeight,
                             rgba: [UInt8](repeating: 0, count: result.cellCount * 4))
        }
        let tint = condition.displayTint
        var rgba = [UInt8](repeating: 0, count: result.cellCount * 4)
        for cell in 0..<result.cellCount {
            let base = cell * 4
            let scaled = max(0, min(1, source.values[cell]))
            rgba[base] = UInt8((scaled * tint.red) * 255)
            rgba[base + 1] = UInt8((scaled * tint.green) * 255)
            rgba[base + 2] = UInt8((scaled * tint.blue) * 255)
            rgba[base + 3] = 255
        }
        return RGBAImage(width: result.gridWidth, height: result.gridHeight, rgba: rgba)
    }

    /// Maps a signed difference to a diverging RGBA-free RGB triple: under-shoots
    /// (positive) trend blue, over-shoots (negative) trend red, zero is black.
    /// Unmatched cells get a neutral gray so they read as "no prediction".
    private static func divergingColor(for difference: Double, matched: Bool) -> (red: UInt8, green: UInt8, blue: UInt8) {
        guard matched else { return (64, 64, 64) }
        let clamped = max(-1, min(1, difference))
        let magnitude = abs(clamped)
        if clamped >= 0 {
            return (0, UInt8(magnitude * 120), UInt8(magnitude * 255))
        } else {
            return (UInt8(magnitude * 255), UInt8(magnitude * 60), 0)
        }
    }

    /// Overlays the magenta unmatched-cell marker onto `image`, which may be
    /// rasterized at `factor` pixels per logical cell (halftone/two-color
    /// modes). The whole `factor × factor` block for an unmatched cell is
    /// marked, since those modes may otherwise have painted paper or a
    /// two-color mix into cells the solver never actually matched.
    private static func previewImage(_ image: RGBAImage, for result: CompositionResult, factor: Int = 1) -> RGBAImage {
        let factor = max(factor, 1)
        precondition(image.width == result.gridWidth * factor && image.height == result.gridHeight * factor)

        var rgba = image.rgba
        for cell in 0..<result.cellCount where result.colorIndices[cell] == nil {
            let cellX = (cell % result.gridWidth) * factor
            let cellY = (cell / result.gridWidth) * factor
            for dy in 0..<factor {
                for dx in 0..<factor {
                    let base = ((cellY + dy) * image.width + cellX + dx) * 4
                    rgba[base] = 255
                    rgba[base + 1] = 0
                    rgba[base + 2] = 255
                    rgba[base + 3] = 255
                }
            }
        }
        return RGBAImage(width: image.width, height: image.height, rgba: rgba)
    }
}
