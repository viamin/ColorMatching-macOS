import XCTest
@testable import ColorComposerCore

final class RasterModeTests: XCTestCase {
    private func color(_ id: Int, _ hex: String, _ responses: [LightingCondition: Double]) -> PaletteColor {
        PaletteColor(
            id: id,
            hex: hex,
            rgb: RGBColor(hex: hex)!,
            responses: responses.mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func grid(_ w: Int, _ h: Int, _ values: [Double]) -> BrightnessGrid {
        BrightnessGrid(width: w, height: h, values: values)
    }

    // MARK: - Halftone coverage matches target brightness

    /// Single channel, 2x1 source, 2x1 grid. Black and white palette. With
    /// pixelsPerCell = 4 each cell is a 4×4 dot, so the halftone coverage
    /// should round to 16·brightness dots of black on white paper.
    func testHalftoneDotCountMatchesCoverage() throws {
        let palette = [
            color(1, "#000000", [.red: 0.0]),
            color(2, "#ffffff", [.red: 1.0])
        ]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: grid(2, 1, [0.0, 0.5])],
            weights: ChannelWeights(red: 1)
        )
        let image = CompositionRenderer.composite(
            result,
            mode: .halftone,
            pixelsPerCell: 4
        )
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 4)
        XCTAssertEqual(image.rgba.count, 8 * 4 * 4)

        // Cell 0 (logical x=0) is the left 4 columns, cell 1 the right 4.
        for cellX in 0..<2 {
            var blackCount = 0
            for dy in 0..<4 {
                for dx in 0..<4 {
                    let byte = (dy * image.width + cellX * 4 + dx) * 4
                    let r = image.rgba[byte]
                    let g = image.rgba[byte + 1]
                    let b = image.rgba[byte + 2]
                    if r == 0 && g == 0 && b == 0 {
                        blackCount += 1
                    } else {
                        XCTAssertEqual(r, 255, "cell \(cellX) (\(dx),\(dy)) should be paper white")
                        XCTAssertEqual(g, 255)
                        XCTAssertEqual(b, 255)
                    }
                    XCTAssertEqual(image.rgba[byte + 3], 255)
                }
            }
            if cellX == 0 {
                XCTAssertEqual(blackCount, 0, "target 0 should produce no dots")
            } else {
                XCTAssertEqual(blackCount, 8, "target 0.5 should produce 8 dots of 16")
            }
        }
    }

    // MARK: - Halftone uses central order, not raster order

    /// Coverage 0.25 in a 4×4 cell. Centered order picks the four central pixels
    /// first; raster order would pick the first row. Assert the first four dot
    /// pixels include the center (1,1) — true for centered, false for raster.
    func testHalftoneUsesCenteredPixelOrder() throws {
        let palette = [
            color(1, "#000000", [.red: 0.0]),
            color(2, "#ffffff", [.red: 1.0])
        ]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: grid(1, 1, [0.25])],
            weights: ChannelWeights(red: 1)
        )
        let image = CompositionRenderer.composite(
            result,
            mode: .halftone,
            pixelsPerCell: 4
        )
        // (1,1) is the center pixel of a 4×4 cell. It must be a black dot.
        let centerOffset = (1 * 4 + 1) * 4
        XCTAssertEqual(image.rgba[centerOffset], 0)
        XCTAssertEqual(image.rgba[centerOffset + 1], 0)
        XCTAssertEqual(image.rgba[centerOffset + 2], 0)
    }

    // MARK: - Halftone uses white paper background for unmatched cells

    func testHalftoneUnmatchedCellIsPaperWhite() throws {
        // No eligible colors -> every cell is unmatched -> halftone falls back
        // to the paper background.
        let palette = [color(1, "#ff0000", [.red: 0.5])] // missing green
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: grid(1, 1, [0.5]), .green: grid(1, 1, [0.5])],
            weights: ChannelWeights(red: 1, green: 1)
        )
        let image = CompositionRenderer.composite(
            result,
            mode: .halftone,
            pixelsPerCell: 2
        )
        for offset in 0..<(2 * 2) {
            let byte = offset * 4
            XCTAssertEqual(image.rgba[byte], 255, "R of pixel \(offset) should be paper white")
            XCTAssertEqual(image.rgba[byte + 1], 255)
            XCTAssertEqual(image.rgba[byte + 2], 255)
            XCTAssertEqual(image.rgba[byte + 3], 255)
        }
    }

    // MARK: - Two-color mode lowers weighted squared error

    /// Four corner colors on the [red, green] unit square. The mid-tone target
    /// (0.5, 0.5) cannot be reached by any single color. A 2×2 two-color
    /// mosaic using 4×4 pixelsPerCell cells averages much closer to the
    /// target than flat single-color cells, so the spatially-averaged
    /// weighted squared error must drop.
    func testTwoColorModeLowersSpatiallyAveragedError() throws {
        let palette = [
            color(1, "#000000", [.red: 0.0, .green: 0.0]),
            color(2, "#ff0000", [.red: 1.0, .green: 0.0]),
            color(3, "#00ff00", [.red: 0.0, .green: 1.0]),
            color(4, "#ffff00", [.red: 1.0, .green: 1.0])
        ]
        let width = 8
        let height = 8
        let count = width * height
        let grids: [LightingCondition: BrightnessGrid] = [
            .red: grid(width, height, Array(repeating: 0.5, count: count)),
            .green: grid(width, height, Array(repeating: 0.5, count: count))
        ]
        let weights = ChannelWeights(red: 1, green: 1)
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        let flat = CompositionRenderer.composite(result, mode: .flat, pixelsPerCell: 4)
        let twoColor = CompositionRenderer.composite(result, mode: .twoColor, pixelsPerCell: 4)
        XCTAssertEqual(flat.width, width * 4)
        XCTAssertEqual(twoColor.width, width * 4)

        let flatError = Self.spatialWeightedSquaredError(
            flat: flat,
            result: result,
            conditions: [.red, .green],
            weights: [1, 1],
            cellPixels: 4
        )
        let twoColorError = Self.spatialWeightedSquaredError(
            flat: twoColor,
            result: result,
            conditions: [.red, .green],
            weights: [1, 1],
            cellPixels: 4
        )
        XCTAssertLessThan(twoColorError, flatError)
    }

    // MARK: - Two-color mix uses only two palette colors per cell

    /// Every pixel in a two-color cell must come from one of the two palette
    /// colors selected for that cell, never from a third.
    func testTwoColorCellUsesOnlyTwoPaletteColors() throws {
        let palette = [
            color(1, "#000000", [.red: 0.0, .green: 0.0]),
            color(2, "#ff0000", [.red: 1.0, .green: 0.0]),
            color(3, "#00ff00", [.red: 0.0, .green: 1.0]),
            color(4, "#ffff00", [.red: 1.0, .green: 1.0])
        ]
        let count = 2 * 2
        let grids: [LightingCondition: BrightnessGrid] = [
            .red: grid(2, 2, Array(repeating: 0.5, count: count)),
            .green: grid(2, 2, Array(repeating: 0.5, count: count))
        ]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: grids,
            weights: ChannelWeights(red: 1, green: 1)
        )
        let image = CompositionRenderer.composite(
            result,
            mode: .twoColor,
            pixelsPerCell: 4
        )
        let paletteRGBs = Set(palette.map { RGB(red: $0.rgb.red, green: $0.rgb.green, blue: $0.rgb.blue) })
        // Inspect each cell independently: the set of colors found must be
        // a subset of the palette of size at most two.
        for y in 0..<2 {
            for x in 0..<2 {
                var cellColors = Set<RGB>()
                for dy in 0..<4 {
                    for dx in 0..<4 {
                        let out = ((y * 4 + dy) * 8 + x * 4 + dx) * 4
                        cellColors.insert(RGB(
                            red: image.rgba[out],
                            green: image.rgba[out + 1],
                            blue: image.rgba[out + 2]
                        ))
                    }
                }
                XCTAssertLessThanOrEqual(cellColors.count, 2)
                XCTAssertTrue(cellColors.isSubset(of: paletteRGBs))
            }
        }
    }

    // MARK: - Flat mode is the v1 baseline (compatibility with no-argument call)

    func testFlatModeMatchesLegacyDefault() throws {
        let palette = [
            color(1, "#000000", [.red: 0.0]),
            color(2, "#ffffff", [.red: 1.0])
        ]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: grid(2, 1, [0.0, 1.0])],
            weights: ChannelWeights(red: 1)
        )
        let explicit = CompositionRenderer.composite(result, mode: .flat)
        let implicit = CompositionRenderer.composite(result)
        XCTAssertEqual(explicit, implicit)
        XCTAssertEqual(explicit.width, 2)
        XCTAssertEqual(explicit.height, 1)
    }

    // MARK: - Output size is logical × pixelsPerCell

    func testRasterOutputSizeScalesWithPixelsPerCell() throws {
        let palette = [
            color(1, "#000000", [.red: 0.0]),
            color(2, "#ffffff", [.red: 1.0])
        ]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: grid(3, 2, Array(repeating: 0.5, count: 6))],
            weights: ChannelWeights(red: 1)
        )
        let image = CompositionRenderer.composite(
            result,
            mode: .halftone,
            pixelsPerCell: 5
        )
        XCTAssertEqual(image.width, 15)
        XCTAssertEqual(image.height, 10)
    }

    // MARK: - RasterMode round-trips through Codable

    func testRasterModeCodableRoundTrip() throws {
        let modes: [RasterMode] = [.flat, .halftone, .twoColor]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mode in modes {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(RasterMode.self, from: data)
            XCTAssertEqual(mode, decoded)
        }
    }

    // MARK: - Helpers

    private struct RGB: Hashable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
    }

    /// Spatially-averaged weighted squared error between the raster's per-cell
    /// averaged reproduction and the target vectors in `result.sourceGrids`,
    /// measured in 4×4 (or any) blocks. Mirrors the helper in DitheringTests
    /// but reads the *rendered* raster rather than the solver's prediction, so
    /// it directly compares the two rendering modes.
    private static func spatialWeightedSquaredError(
        flat: RGBAImage,
        result: CompositionResult,
        conditions: [LightingCondition],
        weights: [Double],
        cellPixels: Int
    ) -> Double {
        precondition(conditions.count == weights.count)
        let cellWidth = flat.width / cellPixels
        let cellHeight = flat.height / cellPixels
        precondition(cellWidth * cellHeight <= result.cellCount)
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return 0 }

        var squaredSum = 0.0
        var cells = 0
        for y in 0..<cellHeight {
            for x in 0..<cellWidth {
                let cellIndex = y * cellWidth + x
                // Per-cell target vector.
                var perChannelTarget: [Double] = []
                for condition in conditions {
                    perChannelTarget.append(result.sourceGrids[condition]!.values[cellIndex])
                }
                // Per-channel reproduction = mean of the 16 raster pixels
                // expressed as 0–1 brightness. We approximate the printed
                // brightness with the linear luminance of the rendered RGB,
                // weighted by the channel's tint so each channel matches its
                // own printed color.
                var perChannelReproduction: [Double] = Array(repeating: 0, count: conditions.count)
                var count = 0
                for dy in 0..<cellPixels {
                    for dx in 0..<cellPixels {
                        let px = x * cellPixels + dx
                        let py = y * cellPixels + dy
                        let out = (py * flat.width + px) * 4
                        let r = Double(flat.rgba[out]) / 255.0
                        let g = Double(flat.rgba[out + 1]) / 255.0
                        let b = Double(flat.rgba[out + 2]) / 255.0
                        for (channel, condition) in conditions.enumerated() {
                            let tint = condition.displayTint
                            let denom = tint.red + tint.green + tint.blue
                            let scalar = denom > 0 ? (r * tint.red + g * tint.green + b * tint.blue) / denom : (r + g + b) / 3
                            perChannelReproduction[channel] += scalar
                        }
                        count += 1
                    }
                }
                if count > 0 {
                    for channel in 0..<conditions.count {
                        perChannelReproduction[channel] /= Double(count)
                    }
                }

                var error = 0.0
                for channel in 0..<conditions.count {
                    let delta = perChannelReproduction[channel] - perChannelTarget[channel]
                    error += weights[channel] * delta * delta
                }
                squaredSum += error
                cells += 1
            }
        }
        return cells > 0 ? squaredSum / Double(cells) : 0
    }
}
