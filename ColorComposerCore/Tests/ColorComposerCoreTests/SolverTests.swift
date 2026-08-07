import XCTest
@testable import ColorComposerCore

final class SolverTests: XCTestCase {
    private func color(_ id: Int, _ hex: String, _ responses: [LightingCondition: Double]) -> PaletteColor {
        let mapped = responses.mapValues { IlluminationResponse(brightness: $0) }
        return PaletteColor(id: id, hex: hex, rgb: RGBColor(hex: hex)!, responses: mapped)
    }

    private func grid(_ w: Int, _ h: Int, _ values: [Double]) -> BrightnessGrid {
        BrightnessGrid(width: w, height: h, values: values)
    }

    func testSelectsNearestColor() throws {
        // Two colors: one dark under red, one bright under red.
        let dark = color(1, "#111111", [.red: 0.1])
        let bright = color(2, "#eeeeee", [.red: 0.9])
        let palette = [dark, bright]

        // Source: left cell dark (0.0), right cell bright (1.0).
        let redGrid = grid(2, 1, [0.0, 1.0])

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: redGrid],
            weights: ChannelWeights(red: 1)
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), 0) // dark color wins for dark target
        XCTAssertEqual(result.colorIndex(x: 1, y: 0), 1) // bright color wins for bright target
        XCTAssertEqual(result.error(x: 0, y: 0), 0.01, accuracy: 1e-9) // (0.1-0)^2
        XCTAssertEqual(result.error(x: 1, y: 0), 0.01, accuracy: 1e-9) // (0.9-1)^2
    }

    func testInversionFlipsSelection() throws {
        let dark = color(1, "#111111", [.red: 0.1])
        let bright = color(2, "#eeeeee", [.red: 0.9])

        let normal = grid(1, 1, [0.0])
        let inverted = grid(1, 1, [0.0]).inverted() // becomes 1.0

        let r1 = try CompositionSolver().solve(
            palette: [dark, bright], sourceGrids: [.red: normal], weights: ChannelWeights(red: 1)
        )
        let r2 = try CompositionSolver().solve(
            palette: [dark, bright], sourceGrids: [.red: inverted], weights: ChannelWeights(red: 1)
        )

        XCTAssertEqual(r1.colorIndex(x: 0, y: 0), 0) // 0.0 target -> dark
        XCTAssertEqual(r2.colorIndex(x: 0, y: 0), 1) // 1.0 target -> bright
    }

    func testExcludesColorMissingRequiredMeasurement() throws {
        // red-only color should be excluded when green is also required.
        let redOnly = color(1, "#ff0000", [.red: 0.5])
        let both = color(2, "#888888", [.red: 0.5, .green: 0.5])
        let palette = [redOnly, both]

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: grid(1, 1, [0.5]), .green: grid(1, 1, [0.5])],
            weights: ChannelWeights(red: 1, green: 1)
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), 1) // only the fully-measured color is eligible
        XCTAssertEqual(result.excludedCandidateCount, 1)
    }

    func testTiesBrokenByEarliestCandidate() throws {
        // Two identical colors: the first in palette order must win.
        let a = color(1, "#aaaaaa", [.red: 0.5])
        let b = color(2, "#bbbbbb", [.red: 0.5])

        let result = try CompositionSolver().solve(
            palette: [a, b],
            sourceGrids: [.red: grid(1, 1, [0.5])],
            weights: ChannelWeights(red: 1)
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), 0)
    }

    func testAllCandidatesExcludedLeavesCellUnmatched() throws {
        let redOnly = color(1, "#ff0000", [.red: 0.5])
        let result = try CompositionSolver().solve(
            palette: [redOnly],
            sourceGrids: [.red: grid(1, 1, [0.5]), .green: grid(1, 1, [0.5])],
            weights: ChannelWeights(red: 1, green: 1)
        )

        XCTAssertNil(result.colorIndex(x: 0, y: 0))
        XCTAssertTrue(result.error(x: 0, y: 0).isInfinite)
        XCTAssertEqual(result.unmatchedCellCount, 1)
    }

    func testThrowsOnEmptyPalette() {
        XCTAssertThrowsError(try CompositionSolver().solve(palette: [], sourceGrids: [:], weights: ChannelWeights(red: 1))) { error in
            XCTAssertEqual(error as? CompositionSolverError, .emptyPalette)
        }
    }

    func testThrowsOnNoActiveConditions() {
        let c = color(1, "#000000", [.red: 0.5])
        XCTAssertThrowsError(
            try CompositionSolver().solve(
                palette: [c], sourceGrids: [.red: grid(1, 1, [0.5])],
                weights: ChannelWeights(white: 0, red: 0, green: 0, blue: 0, lps: 0)
            )
        ) { error in
            XCTAssertEqual(error as? CompositionSolverError, .noActiveConditions)
        }
    }

    func testThrowsOnMissingSourceGridForActiveCondition() {
        let c = color(1, "#000000", [.red: 0.5])
        XCTAssertThrowsError(
            try CompositionSolver().solve(palette: [c], sourceGrids: [:], weights: ChannelWeights(red: 1))
        ) { error in
            XCTAssertEqual(error as? CompositionSolverError, .missingSourceGrid(.red))
        }
    }

    // MARK: - Fast path == general path

    /// A custom scorer that replicates weighted squared error but forces the
    /// solver's general (non-fast) path.
    private struct ReplicaScorer: CompositionScorer {
        func score(candidate: PaletteColor, target: TargetResponseVector, weights: ChannelWeights) -> ScorerResult {
            let active = weights.activeEntries
            for (condition, w) in active where w > 0 {
                if candidate.brightness(for: condition) == nil || target.value(for: condition) == nil {
                    return .excluded
                }
            }
            var sum = 0.0
            for (condition, w) in active {
                let c = candidate.brightness(for: condition) ?? 0
                let t = target.value(for: condition) ?? 0
                let d = c - t
                sum += d * d * w
            }
            return .score(sum)
        }
    }

    func testFastPathAgreesWithGeneralPath() throws {
        let palette = [
            color(1, "#100000", [.white: 0.2, .red: 0.8, .green: 0.1, .lps: 0.5]),
            color(2, "#001100", [.white: 0.7, .red: 0.1, .green: 0.9, .lps: 0.2]),
            color(3, "#000010", [.white: 0.5, .red: 0.5, .green: 0.5]), // missing lps -> excluded for lps weights
            color(4, "#101010", [.white: 0.0, .red: 0.0, .green: 0.0, .lps: 0.0])
        ]
        let weights = ChannelWeights(white: 0.5, red: 1.0, green: 1.0, blue: 0.0, lps: 1.5)

        // 4x4 pseudo-random-ish targets.
        var values: [Double] = []
        for i in 0..<16 { values.append(Double((i * 37) % 100) / 100.0) }
        let grids: [LightingCondition: BrightnessGrid] = [
            .white: grid(4, 4, (0..<16).map { Double(($0 * 7 % 100)) / 100 }),
            .red: grid(4, 4, values),
            .green: grid(4, 4, (0..<16).map { Double(($0 * 13 % 100)) / 100 }),
            .lps: grid(4, 4, (0..<16).map { Double(($0 * 19 % 100)) / 100 })
        ]

        let fast = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        let general = try CompositionSolver(scorer: ReplicaScorer()).solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(fast.colorIndices, general.colorIndices)
        zip(fast.errors, general.errors).forEach {
            XCTAssertEqual($0, $1, accuracy: 1e-9)
        }
    }

    func testHandlesReasonableSizeQuickly() throws {
        // 500x500 with a 256-color palette should complete in a few seconds.
        var palette: [PaletteColor] = []
        for i in 0..<256 {
            let v = Double(i) / 255.0
            palette.append(color(i, String(format: "#%02X%02X%02X", i, i, i), [.red: v, .green: 1 - v]))
        }
        let n = 500 * 500
        var red = [Double](repeating: 0, count: n)
        var green = [Double](repeating: 0, count: n)
        for i in 0..<n { red[i] = Double(i % 100) / 100; green[i] = Double((i * 7) % 100) / 100 }

        let start = Date()
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: [.red: grid(500, 500, red), .green: grid(500, 500, green)],
            weights: ChannelWeights(red: 1, green: 1)
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.cellCount, n)
        XCTAssertEqual(result.unmatchedCellCount, 0)

        // Debug builds are unoptimized (~30x slower); only enforce the wall-clock
        // budget in release, where the algorithm's real cost is visible.
        #if !DEBUG
        XCTAssertLessThan(elapsed, 5, "500x500 solve should be reasonably fast in release")
        #endif
    }
}
