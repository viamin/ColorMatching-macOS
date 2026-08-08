import XCTest
@testable import ColorComposerCore

final class ResponseGamutTests: XCTestCase {
    private func color(_ id: Int, _ hex: String, _ responses: [LightingCondition: Double]) -> PaletteColor {
        PaletteColor(id: id, hex: hex, rgb: RGBColor(hex: hex)!,
                     responses: responses.mapValues { IlluminationResponse(brightness: $0) })
    }

    private func grid(_ values: [Double]) -> BrightnessGrid {
        BrightnessGrid(width: values.count, height: 1, values: values)
    }

    // MARK: - Palette side

    func testVectorsCarryBrightnessInConditionOrder() {
        let gamut = ResponseGamutAnalyzer().analyze(
            palette: [color(1, "#ff0000", [.red: 0.8, .green: 0.2])],
            sourceGrids: [:],
            weights: ChannelWeights(red: 1, green: 1)
        )

        XCTAssertEqual(gamut.conditions, [.red, .green])
        XCTAssertEqual(gamut.vectors.count, 1)
        XCTAssertEqual(gamut.vectors[0].brightness, [0.8, 0.2])
        XCTAssertEqual(gamut.vectors[0].rgb, RGBColor(red: 255, green: 0, blue: 0))
    }

    /// The gamut's eligible set must match the solver's: a color missing an
    /// active measurement is excluded rather than treated as zero brightness.
    func testColorsMissingAnActiveConditionAreExcluded() {
        let gamut = ResponseGamutAnalyzer().analyze(
            palette: [
                color(1, "#000000", [.red: 0.1, .green: 0.1]),
                color(2, "#ffffff", [.red: 0.9])
            ],
            sourceGrids: [:],
            weights: ChannelWeights(red: 1, green: 1)
        )

        XCTAssertEqual(gamut.vectors.map(\.id), [1])
        XCTAssertEqual(gamut.excludedColorCount, 1)
    }

    /// Without source images the palette still plots — this is what guides data
    /// entry before a composition has ever been solved.
    func testPaletteOnlyAnalysisHasNoTargets() {
        let gamut = ResponseGamutAnalyzer().analyze(
            palette: [color(1, "#000000", [.red: 0.5])],
            sourceGrids: [:],
            weights: ChannelWeights(red: 1)
        )

        XCTAssertEqual(gamut.vectors.count, 1)
        XCTAssertTrue(gamut.clusters.isEmpty)
        XCTAssertFalse(gamut.isEmpty)
    }

    func testInactiveConditionsAreNotAxes() {
        let gamut = ResponseGamutAnalyzer().analyze(
            palette: [color(1, "#000000", [.red: 0.5])],
            sourceGrids: [.red: grid([0.5])],
            weights: ChannelWeights(red: 1, blue: 0)
        )

        XCTAssertEqual(gamut.conditions, [.red])
        XCTAssertEqual(gamut.vectors[0].brightness, [0.5])
    }

    // MARK: - Target clustering

    /// Hundreds of thousands of cells must collapse to the handful of distinct
    /// target vectors they actually represent, or the view is unreadable and the
    /// reachability search needlessly repeats itself.
    func testIdenticalTargetsCollapseIntoOneClusterCarryingCellCount() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.5])],
            sourceGrids: [.red: grid([0.51, 0.52, 0.53, 0.11])],
            weights: ChannelWeights(red: 1)
        )

        XCTAssertEqual(gamut.clusters.count, 2)
        XCTAssertEqual(gamut.targetCellCount, 4)
        // The three 0.5x targets share a bin; the 0.11 target sits in its own.
        XCTAssertEqual(gamut.clusters.map(\.cellCount).sorted(), [1, 3])
    }

    func testClusterBrightnessIsBinCenter() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.5])],
            sourceGrids: [.red: grid([0.52])],
            weights: ChannelWeights(red: 1)
        )

        // 0.52 falls in bin 5 of 10 -> center 0.55.
        XCTAssertEqual(gamut.clusters[0].brightness, [0.55])
    }

    func testTargetsAreClusteredAcrossEveryActiveAxis() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.5, .green: 0.5])],
            sourceGrids: [.red: grid([0.05, 0.05]), .green: grid([0.05, 0.95])],
            weights: ChannelWeights(red: 1, green: 1)
        )

        // Same red bin but different green bins -> two distinct clusters.
        XCTAssertEqual(gamut.clusters.count, 2)
        XCTAssertEqual(gamut.clusters.map(\.brightness), [[0.05, 0.05], [0.05, 0.95]])
    }

    func testMissingSourceGridForActiveConditionYieldsNoTargets() {
        let gamut = ResponseGamutAnalyzer().analyze(
            palette: [color(1, "#000000", [.red: 0.5, .green: 0.5])],
            sourceGrids: [.red: grid([0.5])],
            weights: ChannelWeights(red: 1, green: 1)
        )

        XCTAssertTrue(gamut.clusters.isEmpty)
        XCTAssertEqual(gamut.vectors.count, 1)
    }

    // MARK: - Reachability

    func testNearestErrorIsTheBestAchievableWeightedSquaredError() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.05]), color(2, "#808080", [.red: 0.45])],
            sourceGrids: [.red: grid([0.95])],
            weights: ChannelWeights(red: 1)
        )

        // Target bin center 0.95; nearest color is 0.45 -> (0.5)^2 = 0.25.
        XCTAssertEqual(gamut.clusters[0].nearestError, 0.25, accuracy: 1e-9)
    }

    func testNearestErrorHonoursChannelWeights() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.05, .green: 0.05])],
            sourceGrids: [.red: grid([0.95]), .green: grid([0.05])],
            weights: ChannelWeights(red: 4, green: 1)
        )

        // Red differs by 0.9 at weight 4; green matches. 4 * 0.81 = 3.24.
        XCTAssertEqual(gamut.clusters[0].nearestError, 3.24, accuracy: 1e-9)
    }

    func testTargetsBeyondThePaletteAreReportedUnreachable() {
        // Palette tops out at 0.2 under red but the source demands near 1.0.
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.05]), color(2, "#333333", [.red: 0.2])],
            sourceGrids: [.red: grid([0.05, 0.95])],
            weights: ChannelWeights(red: 1)
        )

        let unreachable = gamut.unreachableClusters()
        XCTAssertEqual(unreachable.count, 1)
        XCTAssertEqual(unreachable[0].brightness, [0.95])
        XCTAssertEqual(gamut.unreachableCellCount(), 1)
        XCTAssertEqual(gamut.unreachableFraction(), 0.5, accuracy: 1e-9)
    }

    /// Reachability is a presentation cutoff, not a baked-in verdict, so moving
    /// the threshold must reclassify clusters without re-running the analysis.
    func testThresholdReclassifiesWithoutReanalysis() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.05])],
            sourceGrids: [.red: grid([0.35])],
            weights: ChannelWeights(red: 1)
        )

        // Nearest error is (0.35 - 0.05)^2 = 0.09.
        XCTAssertEqual(gamut.unreachableClusters(threshold: 0.01).count, 1)
        XCTAssertEqual(gamut.unreachableClusters(threshold: 0.5).count, 0)
    }

    func testNoEligibleColorsMakesEveryTargetUnreachable() {
        let gamut = ResponseGamutAnalyzer().analyze(
            palette: [color(1, "#000000", [.green: 0.5])],
            sourceGrids: [.red: grid([0.5, 0.9])],
            weights: ChannelWeights(red: 1)
        )

        XCTAssertTrue(gamut.vectors.isEmpty)
        XCTAssertEqual(gamut.excludedColorCount, 1)
        XCTAssertTrue(gamut.clusters.allSatisfy { $0.nearestError == .infinity })
        XCTAssertEqual(gamut.unreachableCellCount(), 2)
    }

    func testUnreachableFractionIsZeroWithoutTargets() {
        let gamut = ResponseGamutAnalyzer().analyze(
            palette: [color(1, "#000000", [.red: 0.5])],
            sourceGrids: [:],
            weights: ChannelWeights(red: 1)
        )

        XCTAssertEqual(gamut.unreachableFraction(), 0)
    }

    // MARK: - Axis coverage

    func testCoverageReportsBrightnessShortfall() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.05]), color(2, "#333333", [.red: 0.25])],
            sourceGrids: [.red: grid([0.05, 0.95])],
            weights: ChannelWeights(red: 1)
        )

        let axis = gamut.coverage[0]
        XCTAssertEqual(axis.condition, .red)
        XCTAssertEqual(axis.palette, GamutSpan(lowest: 0.05, highest: 0.25))
        XCTAssertEqual(axis.target, GamutSpan(lowest: 0.05, highest: 0.95))
        XCTAssertEqual(axis.shortfallAbove, 0.7, accuracy: 1e-9)
        XCTAssertEqual(axis.shortfallBelow, 0)
        XCTAssertFalse(axis.isCovered)
    }

    /// The whole point of the view: say *why* a region cannot be matched.
    func testGapSummaryNamesTheConditionAndDirection() throws {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.05])],
            sourceGrids: [.red: grid([0.95])],
            weights: ChannelWeights(red: 1)
        )

        let summary = try XCTUnwrap(gamut.coverage[0].gapSummary)
        XCTAssertTrue(summary.contains("bright enough under Red"), "got “\(summary)”")
    }

    func testGapSummaryReportsDarknessShortfall() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#ffffff", [.red: 0.95])],
            sourceGrids: [.red: grid([0.05])],
            weights: ChannelWeights(red: 1)
        )

        let axis = gamut.coverage[0]
        XCTAssertEqual(axis.shortfallBelow, 0.9, accuracy: 1e-9)
        XCTAssertTrue(axis.gapSummary?.contains("dark enough under Red") == true)
    }

    func testCoveredAxisHasNoGapSummary() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.0]), color(2, "#ffffff", [.red: 1.0])],
            sourceGrids: [.red: grid([0.35, 0.65])],
            weights: ChannelWeights(red: 1)
        )

        let axis = gamut.coverage[0]
        XCTAssertTrue(axis.isCovered)
        XCTAssertNil(axis.gapSummary)
        XCTAssertTrue(gamut.gaps.isEmpty)
    }

    func testGapsAreOrderedByWorstShortfallFirst() {
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: [color(1, "#000000", [.red: 0.45, .green: 0.85])],
            sourceGrids: [.red: grid([0.95]), .green: grid([0.95])],
            weights: ChannelWeights(red: 1, green: 1)
        )

        // Red falls short by ~0.5, green by ~0.1.
        XCTAssertEqual(gamut.gaps.map(\.condition), [.red, .green])
    }

    func testCoverageIsEmptyWithoutActiveConditions() {
        let gamut = ResponseGamutAnalyzer().analyze(
            palette: [color(1, "#000000", [.red: 0.5])],
            sourceGrids: [.red: grid([0.5])],
            weights: ChannelWeights()
        )

        XCTAssertTrue(gamut.conditions.isEmpty)
        XCTAssertTrue(gamut.coverage.isEmpty)
        XCTAssertTrue(gamut.clusters.isEmpty)
    }

    // MARK: - Agreement with the solver

    /// The gamut is a diagnostic *for* the solver, so its nearest error must be
    /// the error the solver actually reports for the same target.
    func testNearestErrorAgreesWithSolverForExactBinCenters() throws {
        let palette = [
            color(1, "#000000", [.red: 0.1, .green: 0.9]),
            color(2, "#808080", [.red: 0.6, .green: 0.3]),
            color(3, "#ffffff", [.red: 0.85, .green: 0.05])
        ]
        let weights = ChannelWeights(red: 1.5, green: 0.5)
        // Values chosen to land exactly on bin centers for binsPerAxis = 10.
        let grids: [LightingCondition: BrightnessGrid] = [
            .red: grid([0.05, 0.55, 0.95]),
            .green: grid([0.95, 0.45, 0.15])
        ]

        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        let gamut = ResponseGamutAnalyzer(binsPerAxis: 10).analyze(
            palette: palette, sourceGrids: grids, weights: weights
        )

        // Every cell is a distinct target here, so errors must correspond exactly.
        XCTAssertEqual(gamut.clusters.count, 3)
        XCTAssertEqual(gamut.clusters.map(\.nearestError).sorted(),
                       result.errors.sorted().map { $0 },
                       "gamut reachability must match the solver's achieved error")
    }

    // MARK: - Scale

    /// Hundreds of colors over a large grid must stay bounded by the number of
    /// distinct targets, not the cell count.
    func testLargeGridCollapsesToBoundedClusterCount() {
        let palette = (0..<300).map { index -> PaletteColor in
            let level = Double(index) / 300.0
            return color(index, "#101010", [.red: level, .green: 1 - level])
        }
        let cellCount = 200 * 200
        let red = (0..<cellCount).map { Double($0 % 100) / 100.0 }
        let green = (0..<cellCount).map { Double($0 % 37) / 37.0 }

        let gamut = ResponseGamutAnalyzer(binsPerAxis: 12).analyze(
            palette: palette,
            sourceGrids: [
                .red: BrightnessGrid(width: 200, height: 200, values: red),
                .green: BrightnessGrid(width: 200, height: 200, values: green)
            ],
            weights: ChannelWeights(red: 1, green: 1)
        )

        XCTAssertEqual(gamut.vectors.count, 300)
        XCTAssertEqual(gamut.targetCellCount, cellCount)
        XCTAssertLessThanOrEqual(gamut.clusters.count, 12 * 12)
    }
}
