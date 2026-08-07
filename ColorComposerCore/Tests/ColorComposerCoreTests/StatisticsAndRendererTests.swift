import XCTest
@testable import ColorComposerCore

final class StatisticsAndRendererTests: XCTestCase {
    private func color(_ id: Int, _ hex: String, _ responses: [LightingCondition: Double]) -> PaletteColor {
        PaletteColor(id: id, hex: hex, rgb: RGBColor(hex: hex)!,
                     responses: responses.mapValues { IlluminationResponse(brightness: $0) })
    }

    private func solve() throws -> CompositionResult {
        let palette = [
            color(1, "#000000", [.red: 0.0]),
            color(2, "#ffffff", [.red: 1.0])
        ]
        return try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 2, height: 1, values: [0.0, 1.0])],
            weights: ChannelWeights(red: 1)
        )
    }

    func testErrorStatistics() throws {
        let result = try solve()
        let stats = ErrorStatistics(result: result)

        XCTAssertEqual(stats.matchedCellCount, 2)
        XCTAssertEqual(stats.mean, 0.0, accuracy: 1e-9) // exact matches
        XCTAssertEqual(stats.maximum, 0.0, accuracy: 1e-9)
    }

    func testFractionBelowThreshold() throws {
        let result = try solve()
        let stats = ErrorStatistics(result: result)
        XCTAssertEqual(stats.fractionBelow(threshold: 0.001, result: result), 1.0, accuracy: 1e-9)
        XCTAssertEqual(stats.fractionBelow(threshold: 0.0, result: result), 0.0, accuracy: 1e-9)
    }

    func testCompositeUsesSelectedPaletteColors() throws {
        let result = try solve()
        let image = CompositionRenderer.composite(result)

        XCTAssertEqual(image.width, 2)
        // Cell 0 -> black, cell 1 -> white.
        XCTAssertEqual(image.rgba[0], 0)   // R of black
        XCTAssertEqual(image.rgba[3], 255) // A of black
        XCTAssertEqual(image.rgba[4], 255) // R of white
        XCTAssertEqual(image.rgba[7], 255) // A of white
    }

    func testLightingPreviewUsesMeasuredBrightness() throws {
        let result = try solve()
        let preview = CompositionRenderer.lightingPreview(result, for: .red)

        XCTAssertEqual(preview.value(x: 0, y: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(preview.value(x: 1, y: 0), 1.0, accuracy: 1e-9)
    }

    func testLightingPreviewMissingMeasurementIsBlack() throws {
        // Colors have no green measurement -> preview is black everywhere.
        let palette = [color(1, "#000000", [.red: 0.0])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [0.0])],
            weights: ChannelWeights(red: 1)
        )
        let preview = CompositionRenderer.lightingPreview(result, for: .green)
        XCTAssertEqual(preview.value(x: 0, y: 0), 0.0)
    }

    func testTintedLightingPreviewUsesChannelColor() throws {
        // Two cells: dark (0.0) and bright (1.0) under red.
        let palette = [color(1, "#ffffff", [.red: 0.0]), color(2, "#000000", [.red: 1.0])]
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 2, height: 1, values: [0.0, 1.0])],
            weights: ChannelWeights(red: 1)
        )
        let red = CompositionRenderer.lightingPreviewTinted(result, for: .red)
        // Bright cell -> full red, zero green/blue. Dark cell -> black.
        XCTAssertEqual(red.rgba[4], 255) // R
        XCTAssertEqual(red.rgba[5], 0)   // G
        XCTAssertEqual(red.rgba[6], 0)   // B
        XCTAssertEqual(red.rgba[0], 0)   // dark cell R

        let lps = CompositionRenderer.lightingPreviewTinted(result, for: .lps)
        // No lps measurements -> black, but still opaque.
        XCTAssertEqual(lps.rgba[7], 255)
    }
    func testErrorMapNormalizesToUnitRange() throws {
        let palette = [
            color(1, "#000000", [.red: 0.0]),
            color(2, "#808080", [.red: 0.5])
        ]
        // Target 1.0: color2 (0.5) is closest with error 0.25; color1 error 1.0.
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: BrightnessGrid(width: 1, height: 1, values: [1.0])],
            weights: ChannelWeights(red: 1)
        )
        let map = CompositionRenderer.errorMap(result)
        // Single matched cell -> it is the max -> brightness 1.0.
        XCTAssertEqual(map.value(x: 0, y: 0), 1.0, accuracy: 1e-9)
    }

    func testBrightnessGridInversion() {
        let grid = BrightnessGrid(width: 2, height: 1, values: [0.2, 0.8])
        let inverted = grid.inverted()
        XCTAssertEqual(inverted.values.count, 2)
        XCTAssertEqual(inverted.values[0], 0.8, accuracy: 1e-9)
        XCTAssertEqual(inverted.values[1], 0.2, accuracy: 1e-9)
    }

    func testBrightnessGridUpsampleBlocksCells() {
        // 2x1 upsampled by 3 -> 6 wide x 3 tall, each cell a 3x3 block.
        let grid = BrightnessGrid(width: 2, height: 1, values: [0.1, 0.9])
        let up = grid.upsampled(by: 3)
        XCTAssertEqual(up.width, 6)
        XCTAssertEqual(up.height, 3)
        let expected = [Double](repeating: 0.1, count: 3) + [Double](repeating: 0.9, count: 3)
        XCTAssertEqual(up.values, expected + expected + expected)
    }
}
