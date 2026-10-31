import XCTest
@testable import ColorComposerCore

/// Replays the committed golden-vector corpus through
/// `WeightedSquaredErrorScorer` and `CompositionSolver` and asserts exact
/// agreement with the Elixir `ColorMatching.WeightedSquaredError` solver
/// (issue #39; corpus from viamin/color_matching#111).
///
/// Mirror of the server-side `ColorMatching.Parity.CorpusTest`. Any change in
/// missing-measurement exclusion, earliest-index tie-breaking, or channel
/// weighting shows up here as a mismatch and requires the server to bump the
/// corpus `algorithm_version` and this fixture to be refreshed.
///
/// Score comparisons use exact `==`: every channel value and weight in the
/// corpus is a dyadic rational, so the arithmetic is exact in IEEE-754
/// doubles and any last-bit divergence is a real semantic difference.
final class SolverParityCorpusTests: XCTestCase {
    private var corpus: ParityCorpus!

    override func setUpWithError() throws {
        corpus = try ParityCorpusFixture.load()
    }

    // MARK: - Corpus stamp

    func testCorpusStampMatchesCurrentSolverSemantics() throws {
        XCTAssertEqual(corpus.algorithmVersion, 1, "corpus semantics moved; refresh the fixture (docs/solver-parity-corpus.md)")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map(\.rawValue))
        XCTAssertGreaterThanOrEqual(corpus.scenarios.count, 12)
    }

    func testCorpusContainsTieAndNullSelectionScenarios() {
        let tied = corpus.scenarios.filter { $0.expected.tieBroke == true }
        let unselected = corpus.scenarios.filter { $0.expected.selectedIndex == nil }
        XCTAssertGreaterThanOrEqual(tied.count, 1, "corpus must keep exercising tie-breaking")
        XCTAssertGreaterThanOrEqual(unselected.count, 1, "corpus must keep exercising exclusion-only scenarios")
    }

    // MARK: - Scorer-level parity (includes target-missing scenarios)

    func testScorerReproducesEveryExpectedScoreExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let palette = try scenario.paletteColors()
            let target = scenario.target.toTarget
            let weights = scenario.channelWeights

            XCTAssertEqual(
                scenario.expected.scores.count, palette.count,
                "\(scenario.id): score count must match palette size"
            )
            for (offset, expected) in scenario.expected.scores.enumerated() {
                XCTAssertEqual(expected.index, offset, "\(scenario.id): scores must be indexed in palette order")
                assertScoreMatches(
                    scorer.score(candidate: palette[offset], target: target, weights: weights),
                    expected.score,
                    scenario: scenario.id, candidate: offset
                )
            }
        }
    }

    func testBestMatchSelectionMatchesExpectedIncludingTies() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let palette = try scenario.paletteColors()
            let target = scenario.target.toTarget
            let weights = scenario.channelWeights

            let scored: [CorpusScore] = palette.map {
                CorpusScore($0, scoredBy: scorer, target: target, weights: weights)
            }
            let finite: [(index: Int, score: Double)] = scored.enumerated().compactMap { pair in
                guard case .score(let value) = pair.element else { return nil }
                return (pair.offset, value)
            }

            guard scenario.expected.selectedIndex != nil else {
                XCTAssertTrue(finite.isEmpty, "\(scenario.id): expected no selection but got finite scores \(finite)")
                XCTAssertNil(scenario.expected.error)
                XCTAssertTrue(scenario.expected.tiedIndices.isEmpty)
                continue
            }

            let best = try XCTUnwrap(finite.min { $0.score < $1.score }, "\(scenario.id): expected a selection but every candidate is excluded")
            let tied = finite.filter { $0.score == best.score }.map(\.index)

            XCTAssertEqual(best.index, scenario.expected.selectedIndex, "\(scenario.id): selected index")
            XCTAssertEqual(palette[best.index].hex, scenario.expected.selectedHexColor, "\(scenario.id): selected hex")
            XCTAssertEqual(best.score, scenario.expected.error, "\(scenario.id): best error")
            XCTAssertEqual(tied, scenario.expected.tiedIndices, "\(scenario.id): tied indices")
            XCTAssertEqual(scenario.expected.tieBroke, tied.count > 1, "\(scenario.id): tie evidence")
        }
    }

    // MARK: - Solver-level parity (production fast path)

    func testSolverSelectsExpectedColorOnSingleCellComposition() throws {
        let solver = CompositionSolver(scorer: WeightedSquaredErrorScorer())

        for scenario in corpus.scenarios {
            guard scenario.isExpressibleAsSourceGrids else {
                // `missing-target-excluded` is only expressible at the scorer
                // level (dense grids always provide the target) — covered above.
                XCTAssertEqual(scenario.id, "missing-target-excluded")
                continue
            }
            let result = try solver.solve(
                palette: try scenario.paletteColors(),
                sourceGrids: try scenario.sourceGrids(),
                weights: scenario.channelWeights
            )

            XCTAssertEqual(scenario.expected.selectedIndex, result.colorIndex(x: 0, y: 0), "\(scenario.id): solver selection")
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, "\(scenario.id): solver error")
            } else {
                XCTAssertEqual(result.unmatchedCellCount, 1, "\(scenario.id): every candidate excluded must leave the cell unmatched")
                XCTAssertEqual(result.error(x: 0, y: 0), .infinity)
            }
            XCTAssertEqual(
                result.excludedCandidateCount,
                scenario.expected.scores.filter { $0.score == .excluded }.count,
                "\(scenario.id): excluded-candidate diagnostics"
            )
        }
    }

    // MARK: - Policy spot checks (names the semantics the corpus encodes)

    /// `missing-candidate-excluded`: a candidate matching the target on every
    /// measured channel but missing a positive-weight channel is excluded —
    /// never treated as zero brightness (which would score 0.0 and win here,
    /// because the target's lps is 0.0).
    func testMissingMeasurementExcludedNotTreatedAsZero() throws {
        let scenario = try XCTUnwrap(corpus.scenarios.first { $0.id == "missing-candidate-excluded" })

        XCTAssertEqual(scenario.expected.scores.first?.score, .excluded)
        XCTAssertEqual(scenario.expected.selectedIndex, 1)
        XCTAssertEqual(scenario.expected.tiedIndices, [1])
    }

    /// `zero-weight-channel-missing`: a candidate missing a zero-weight
    /// channel neither excludes nor contributes — it ties exactly with a
    /// fully-measured candidate whose blue differs wildly.
    func testZeroWeightChannelNeitherExcludesNorContributes() throws {
        let scenario = try XCTUnwrap(corpus.scenarios.first { $0.id == "zero-weight-channel-missing" })
        let weights = scenario.channelWeights

        XCTAssertEqual(weights.blue, 0)
        XCTAssertFalse(scenario.palette[0].channels.keys.contains("blue"), "scenario setup: first candidate is missing blue")
        XCTAssertEqual(scenario.expected.scores.first?.score, .score(0.0625))
        XCTAssertEqual(scenario.expected.selectedIndex, 0, "earliest member of the tied pair wins")
        XCTAssertEqual(scenario.expected.tiedIndices, [0, 1])
    }

    /// `unknown-weight-ignored`: weight keys for light sources no vector can
    /// measure (ultraviolet) are dropped, so selection matches the
    /// `distinct-errors` scenario verbatim.
    func testUnknownWeightKeysAreIgnored() throws {
        let scenario = try XCTUnwrap(corpus.scenarios.first { $0.id == "unknown-weight-ignored" })
        let reference = try XCTUnwrap(corpus.scenarios.first { $0.id == "distinct-errors" })

        XCTAssertEqual(scenario.weights["ultraviolet"], 3.0, "scenario setup: carries an unknown light source")
        XCTAssertEqual(scenario.channelWeights, reference.channelWeights)
        XCTAssertEqual(scenario.expected.selectedIndex, reference.expected.selectedIndex)
        XCTAssertEqual(scenario.expected.error, reference.expected.error)
        XCTAssertEqual(scenario.expected.scores, reference.expected.scores)
    }

    // MARK: - Helpers

    private func assertScoreMatches(
        _ result: ScorerResult,
        _ expected: CorpusScore,
        scenario: String,
        candidate: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (result, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let value), .score(let expectedValue)):
            XCTAssertEqual(value, expectedValue, "\(scenario): candidate \(candidate) score", file: file, line: line)
        case (.score, .excluded):
            XCTFail("\(scenario): candidate \(candidate) scored but corpus expects excluded", file: file, line: line)
        case (.excluded, .score(let expectedValue)):
            XCTFail("\(scenario): candidate \(candidate) excluded but corpus expects score \(expectedValue)", file: file, line: line)
        }
    }
}

/// Bridges a `ScorerResult` into the corpus score space for selection checks.
private extension CorpusScore {
    init(
        _ candidate: PaletteColor,
        scoredBy scorer: WeightedSquaredErrorScorer,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) {
        switch scorer.score(candidate: candidate, target: target, weights: weights) {
        case .score(let value): self = .score(value)
        case .excluded: self = .excluded
        }
    }
}
