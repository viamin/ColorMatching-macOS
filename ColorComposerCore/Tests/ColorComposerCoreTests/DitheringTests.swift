import XCTest
@testable import ColorComposerCore

final class DitheringTests: XCTestCase {
    private func color(_ id: Int, _ hex: String, _ responses: [LightingCondition: Double]) -> PaletteColor {
        let mapped = responses.mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(id: id, hex: hex, rgb: RGBColor(hex: hex)!, responses: mapped)
    }

    private func grid(_ w: Int, _ h: Int, _ values: [Double]) -> BrightnessGrid {
        BrightnessGrid(width: w, height: h, values: values)
    }

    // MARK: - Default behavior unchanged when dithering is off

    func testOffMatchesCallingWithoutDithering() throws {
        let palette = [color(1, "#000000", [.red: 0.0]), color(2, "#ffffff", [.red: 1.0])]
        let target = (0..<16).map { Double($0) / 15 }
        let grids: [LightingCondition: BrightnessGrid] = [.red: grid(16, 1, target)]

        let omitted = try CompositionSolver().solve(
            palette: palette, sourceGrids: grids, weights: ChannelWeights(red: 1)
        )
        let explicit = try CompositionSolver().solve(
            palette: palette, sourceGrids: grids, weights: ChannelWeights(red: 1), dithering: .off
        )

        XCTAssertEqual(omitted.colorIndices, explicit.colorIndices)
        zip(omitted.errors, explicit.errors).forEach { XCTAssertEqual($0, $1, accuracy: 1e-12) }
    }

    // MARK: - Determinism

    func testFloydSteinbergIsDeterministic() throws {
        let palette = [color(1, "#000000", [.red: 0.0]), color(2, "#ffffff", [.red: 1.0])]
        let target = (0..<16).map { Double($0) / 15 }
        let grids: [LightingCondition: BrightnessGrid] = [.red: grid(16, 1, target)]

        let a = try CompositionSolver().solve(
            palette: palette, sourceGrids: grids, weights: ChannelWeights(red: 1), dithering: .floydSteinberg
        )
        let b = try CompositionSolver().solve(
            palette: palette, sourceGrids: grids, weights: ChannelWeights(red: 1), dithering: .floydSteinberg
        )

        XCTAssertEqual(a.colorIndices, b.colorIndices)
        zip(a.errors, b.errors).forEach { XCTAssertEqual($0, $1, accuracy: 1e-12) }
    }

    // MARK: - Hand-computed small case

    /// Vector Floyd–Steinberg on a 1×3 grid, single channel, palette {0.0, 1.0},
    /// constant target 0.6. Only the rightward (7/16) term applies in one row.
    ///
    /// Cell 0: adj 0.6   → pick 1 (error vs 0.6 = 0.16); push (0.6 − 1)·7/16.
    /// Cell 1: adj 0.425 → pick 0 (error vs 0.6 = 0.36); push (0.425 − 0)·7/16.
    /// Cell 2: adj ~0.79 → pick 1 (error vs 0.6 = 0.16).
    func testMatchesHandComputedSmallCase() throws {
        let palette = [color(1, "#000000", [.red: 0.0]), color(2, "#ffffff", [.red: 1.0])]
        let grids: [LightingCondition: BrightnessGrid] = [.red: grid(3, 1, [0.6, 0.6, 0.6])]

        let result = try CompositionSolver().solve(
            palette: palette, sourceGrids: grids, weights: ChannelWeights(red: 1), dithering: .floydSteinberg
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), 1)
        XCTAssertEqual(result.colorIndex(x: 1, y: 0), 0)
        XCTAssertEqual(result.colorIndex(x: 2, y: 0), 1)
        XCTAssertEqual(result.error(x: 0, y: 0), 0.16, accuracy: 1e-9)
        XCTAssertEqual(result.error(x: 1, y: 0), 0.36, accuracy: 1e-9)
        XCTAssertEqual(result.error(x: 2, y: 0), 0.16, accuracy: 1e-9)
    }

    // MARK: - Gradient de-posterizes (spatially-averaged error drops)

    /// A smooth gradient through a two-color palette: nearest-neighbor bands
    /// into 0s and 1s, while Floyd–Steinberg dithers so block averages track
    /// the ramp. Assert the block-averaged (tonal) error falls well below NN.
    func testGradientDePosterizes() throws {
        let palette = [color(1, "#000000", [.red: 0.0]), color(2, "#ffffff", [.red: 1.0])]
        let width = 40
        let height = 8
        let target = (0..<(width * height)).map { Double($0 % width) / Double(width - 1) }
        let grids: [LightingCondition: BrightnessGrid] = [.red: grid(width, height, target)]
        let weights = ChannelWeights(red: 1)

        let nn = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        let fs = try CompositionSolver().solve(
            palette: palette, sourceGrids: grids, weights: weights, dithering: .floydSteinberg
        )

        let nnError = Self.blockMeanSquaredError(result: nn, condition: .red, target: target,
                                                 width: width, height: height, block: 8)
        let fsError = Self.blockMeanSquaredError(result: fs, condition: .red, target: target,
                                                 width: width, height: height, block: 8)

        XCTAssertLessThan(fsError, nnError, "Floyd–Steinberg should reduce spatially-averaged error")
        XCTAssertLessThan(fsError, nnError * 0.5, "reduction should be substantial, not marginal")
    }

    // MARK: - Vector case: mid-tone on a corner palette

    /// Four corner colors on the [red, green] unit square; target the unsolvable
    /// mid tone (0.5, 0.5). Nearest-neighbor collapses to one corner for every
    /// cell; dithering spreads selections so each channel's average moves toward
    /// 0.5 — the vector de-posterization effect.
    func testVectorDitheringAveragesTowardTargetTone() throws {
        let palette = [
            color(1, "#000000", [.red: 0.0, .green: 0.0]),
            color(2, "#ff0000", [.red: 1.0, .green: 0.0]),
            color(3, "#00ff00", [.red: 0.0, .green: 1.0]),
            color(4, "#ffff00", [.red: 1.0, .green: 1.0])
        ]
        let count = 12 * 12
        let grids: [LightingCondition: BrightnessGrid] = [
            .red: grid(12, 12, Array(repeating: 0.5, count: count)),
            .green: grid(12, 12, Array(repeating: 0.5, count: count))
        ]
        let weights = ChannelWeights(red: 1, green: 1)

        let nn = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        let fs = try CompositionSolver().solve(
            palette: palette, sourceGrids: grids, weights: weights, dithering: .floydSteinberg
        )

        let nnOffset = Self.channelOffset(result: nn, conditions: [.red, .green], target: 0.5)
        let fsOffset = Self.channelOffset(result: fs, conditions: [.red, .green], target: 0.5)

        XCTAssertLessThan(fsOffset, nnOffset, "vector dithering should move averages toward the target tone")
        XCTAssertLessThan(fsOffset, 0.1, "averages should land close to the target tone")
    }

    // MARK: - All candidates excluded

    func testDitheringLeavesCellUnmatchedWhenAllCandidatesExcluded() throws {
        let palette = [color(1, "#ff0000", [.red: 0.5])] // missing green
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: grid(1, 1, [0.5]), .green: grid(1, 1, [0.5])],
            weights: ChannelWeights(red: 1, green: 1),
            dithering: .floydSteinberg
        )

        XCTAssertNil(result.colorIndex(x: 0, y: 0))
        XCTAssertTrue(result.error(x: 0, y: 0).isInfinite)
        XCTAssertEqual(result.unmatchedCellCount, 1)
    }

    // MARK: - Helpers

    /// Mean squared error between each block's average reproduced brightness and
    /// the block's average target — the tonal-reproduction metric error diffusion
    /// is meant to improve (as opposed to per-cell error, which it trades away).
    private static func blockMeanSquaredError(
        result: CompositionResult,
        condition: LightingCondition,
        target: [Double],
        width: Int,
        height: Int,
        block: Int
    ) -> Double {
        let reproduced = (0..<result.cellCount).map { cell -> Double in
            guard let index = result.colorIndices[cell] else { return 0 }
            return result.palette[index].brightness(for: condition) ?? 0
        }

        var squaredSum = 0.0
        var blocks = 0
        for y in stride(from: 0, to: height, by: block) {
            for x in stride(from: 0, to: width, by: block) {
                let blockHeight = min(block, height - y)
                let blockWidth = min(block, width - x)
                var reproSum = 0.0
                var targetSum = 0.0
                for dy in 0..<blockHeight {
                    for dx in 0..<blockWidth {
                        let cell = (y + dy) * width + (x + dx)
                        reproSum += reproduced[cell]
                        targetSum += target[cell]
                    }
                }
                let cells = Double(blockHeight * blockWidth)
                let delta = (reproSum / cells) - (targetSum / cells)
                squaredSum += delta * delta
                blocks += 1
            }
        }
        return blocks > 0 ? squaredSum / Double(blocks) : 0
    }

    /// Sum of |mean(channel) − target| across channels — how far a composition's
    /// averaged reproduction lands from a constant target tone.
    private static func channelOffset(
        result: CompositionResult,
        conditions: [LightingCondition],
        target: Double
    ) -> Double {
        var total = 0.0
        for condition in conditions {
            let matched = result.colorIndices.compactMap { $0 }
            guard !matched.isEmpty else { continue }
            let sum = matched.reduce(0.0) { $0 + (result.palette[$1].brightness(for: condition) ?? 0) }
            total += abs((sum / Double(matched.count)) - target)
        }
        return total
    }
}
