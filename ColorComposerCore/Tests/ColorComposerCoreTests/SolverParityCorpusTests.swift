import XCTest
@testable import ColorComposerCore

/// Solver parity against the golden-vector corpus published by the
/// `color_matching` server (`priv/parity/v1/corpus.json`, upstream
/// `mix parity.generate` — viamin/color_matching#112).
///
/// Every scenario is replayed through `WeightedSquaredErrorScorer` and the
/// full `CompositionSolver` pipeline and must agree with the Elixir
/// `ColorMatching.WeightedSquaredError` results *exactly*: per-candidate
/// scores, the selected index, the selected hex, tie-break evidence, and the
/// missing-measurement exclusion policy. The corpus values are dyadic
/// rationals, so exact floating-point equality is meaningful here.
///
/// Refreshing the corpus is a deliberate act — see
/// `docs/solver-parity-corpus.md`.
final class SolverParityCorpusTests: XCTestCase {
    private var corpus: ParityCorpus!

    override func setUpWithError() throws {
        corpus = try ParityCorpus.load()
    }

    private func scenario(_ id: String) throws -> ParityCorpus.Scenario {
        try XCTUnwrap(corpus.scenarios.first { $0.id == id }, "Corpus scenario '\(id)' not found — was the corpus refreshed? (see docs/solver-parity-corpus.md)")
    }

    /// Palette in corpus index order, validated contiguous from zero.
    private func domainPalette(for scenario: ParityCorpus.Scenario) throws -> [PaletteColor] {
        let sorted = scenario.palette.sorted { $0.index < $1.index }
        XCTAssertEqual(sorted.enumerated().map(\.element.index), Array(sorted.indices),
                       "Scenario '\(scenario.id)': palette indices must be contiguous from 0")
        return try sorted.map { candidate in
            try XCTUnwrap(candidate.toPaletteColor(), "Scenario '\(scenario.id)': unparseable hex \(candidate.hexColor)")
        }
    }

    private func scoreCandidate(_ candidate: PaletteColor, _ target: TargetResponseVector, _ weights: ChannelWeights) -> ScorerResult {
        WeightedSquaredErrorScorer().score(candidate: candidate, target: target, weights: weights)
    }

    // MARK: - Corpus contract stamps

    /// The corpus carries explicit versioning stamps; a corpus bump that
    /// changes any of them must be a conscious refresh, not a silent drift.
    func testCorpusMetadataMatchesV1Contract() throws {
        XCTAssertEqual(corpus.algorithmVersion, 1, "algorithm_version stamp changed — refresh is deliberate")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(Set(corpus.lightSources), Set(["white", "red", "green", "blue", "lps"]))

        let ids = corpus.scenarios.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Scenario ids must be unique")
        XCTAssertTrue(ids.contains { $0.contains("tie") }, "Corpus must keep tie coverage")
        XCTAssertTrue(ids.contains { $0.contains("excluded") }, "Corpus must keep exclusion coverage")
    }

    // MARK: - Full replay

    /// Every scenario must agree with the corpus exactly: per-candidate
    /// scores, selection, tie evidence, and error.
    func testAllScenariosMatchExpectedScoresSelectionsAndTies() throws {
        for scenario in corpus.scenarios {
            try XCTContext.runActivity(named: scenario.id) { _ in
                try replay(scenario)
            }
        }
    }

    private func replay(_ scenario: ParityCorpus.Scenario) throws {
        let weights = ChannelWeights(parityWeights: scenario.weights)
        let palette = try domainPalette(for: scenario)
        let target = scenario.target.toTarget()

        var best: Double?
        var tiedIndices: [Int] = []
        for entry in scenario.expected.scores {
            let result = scoreCandidate(palette[entry.index], target, weights)
            switch (result, entry.score) {
            case (.excluded, .excluded):
                continue
            case (.score(let value), .value(let expected)):
                XCTAssertEqual(value, expected, accuracy: 1e-12,
                               "Scenario '\(scenario.id)' candidate \(entry.index): score mismatch")
                if best == nil || value < best! {
                    best = value
                    tiedIndices = [entry.index]
                } else if value == best {
                    tiedIndices.append(entry.index)
                }
            case (.score(let value), .excluded):
                XCTFail("Scenario '\(scenario.id)' candidate \(entry.index): expected excluded, got score \(value)")
            case (.excluded, .value(let expected)):
                XCTFail("Scenario '\(scenario.id)' candidate \(entry.index): expected score \(expected), got excluded")
            }
        }

        let expected = scenario.expected
        XCTAssertEqual(tiedIndices, expected.tiedIndices, "Scenario '\(scenario.id)': tied set mismatch")
        switch (best, expected.error) {
        case (nil, nil):
            break
        case (let best?, let expectedError?):
            XCTAssertEqual(best, expectedError, accuracy: 1e-12, "Scenario '\(scenario.id)': winning error mismatch")
        default:
            XCTFail("Scenario '\(scenario.id)': expected error \(String(describing: expected.error)), got \(String(describing: best))")
        }

        if let selectedIndex = expected.selectedIndex {
            XCTAssertEqual(tiedIndices.first, selectedIndex,
                           "Scenario '\(scenario.id)': earliest-index-wins selection mismatch")
            XCTAssertEqual(palette[selectedIndex].hex, expected.selectedHexColor,
                           "Scenario '\(scenario.id)': selected hex mismatch")
            XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1)
        } else {
            XCTAssertTrue(tiedIndices.isEmpty, "Scenario '\(scenario.id)': expected no selection")
            XCTAssertNil(expected.tieBroke)
            XCTAssertNil(expected.error)
        }
    }

    /// The production selection path (`CompositionSolver` with its contiguous
    /// fast path) must land on the same cell as the corpus for every scenario
    /// whose target vector is complete, including the unmatched-cell outcome
    /// when every candidate is excluded.
    func testSolverPipelineAgreesWithCorpusSelection() throws {
        for scenario in corpus.scenarios {
            let weights = ChannelWeights(parityWeights: scenario.weights)
            let active = weights.activeEntries
            let target = scenario.target.toTarget()
            let targetComplete = active.allSatisfy { target.value(for: $0.condition) != nil }
            if !targetComplete { continue } // target-side exclusion is scorer-level only

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for (condition, _) in active {
                grids[condition] = BrightnessGrid(width: 1, height: 1, fill: target.value(for: condition)!)
            }
            let palette = try domainPalette(for: scenario)
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex,
                           "Scenario '\(scenario.id)': solver selection mismatch")
            if let error = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), error, accuracy: 1e-12)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite)
                XCTAssertEqual(result.unmatchedCellCount, 1)
                XCTAssertEqual(result.excludedCandidateCount, palette.count)
            }
        }
    }

    // MARK: - Focused coverage

    /// Tie scenarios: the earliest member of the tied set must win, and every
    /// tied candidate must share the winning score exactly.
    func testTieScenariosSelectEarliestTiedIndex() throws {
        for id in ["tie-symmetric-around-target", "tie-duplicate-vectors", "tie-three-way-on-lps", "mixed-large-palette"] {
            let scenario = try scenario(id)
            let expected = scenario.expected
            XCTAssertEqual(expected.tieBroke, true, "Scenario '\(id)' must remain a tie scenario")
            XCTAssertGreaterThan(expected.tiedIndices.count, 1)
            XCTAssertEqual(expected.selectedIndex, expected.tiedIndices.first,
                           "Scenario '\(id)': earliest tied index must win")

            let weights = ChannelWeights(parityWeights: scenario.weights)
            let palette = try domainPalette(for: scenario)
            let target = scenario.target.toTarget()
            var tiedScores: [Double] = []
            for index in expected.tiedIndices {
                guard case .score(let value) = scoreCandidate(palette[index], target, weights) else {
                    return XCTFail("Scenario '\(id)': tied candidate \(index) unexpectedly excluded")
                }
                tiedScores.append(value)
            }
            XCTAssertTrue(tiedScores.allSatisfy { $0 == tiedScores.first },
                          "Scenario '\(id)': tied candidates must score identically")
            XCTAssertEqual(tiedScores.first, try XCTUnwrap(expected.error), accuracy: 1e-12)
        }
    }

    /// A candidate missing a positively-weighted channel is excluded — never
    /// treated as zero brightness — and can therefore never win.
    func testMissingMeasurementExcludesRatherThanTreatingAsZero() throws {
        let scenario = try scenario("missing-candidate-excluded")
        let expected = scenario.expected
        let weights = ChannelWeights(parityWeights: scenario.weights)
        let palette = try domainPalette(for: scenario)
        let target = scenario.target.toTarget()

        XCTAssertEqual(expected.scores.first { $0.index == 0 }?.score, .excluded)
        XCTAssertNil(palette[0].brightness(for: .lps))
        XCTAssertNotEqual(expected.selectedIndex, 0)

        let allExcluded = try scenario("all-excluded")
        XCTAssertEqual(allExcluded.expected.selectedIndex, nil)
        XCTAssertTrue(allExcluded.expected.scores.allSatisfy { $0.score == .excluded })
        for candidate in try domainPalette(for: allExcluded) {
            XCTAssertEqual(scoreCandidate(candidate, allExcluded.target.toTarget(),
                                          ChannelWeights(parityWeights: allExcluded.weights)), .excluded)
        }
    }

    /// When the *target* lacks a positively-weighted channel, every candidate
    /// is excluded and no selection exists.
    func testTargetMissingChannelExcludesAllCandidates() throws {
        let scenario = try scenario("missing-target-excluded")
        let weights = ChannelWeights(parityWeights: scenario.weights)
        let target = scenario.target.toTarget()
        let missing = weights.activeConditions.filter { target.value(for: $0) == nil }
        XCTAssertEqual(missing, [.white])

        for candidate in try domainPalette(for: scenario) {
            XCTAssertEqual(scoreCandidate(candidate, target, weights), .excluded)
        }
        XCTAssertNil(scenario.expected.selectedIndex)
        XCTAssertTrue(scenario.expected.tiedIndices.isEmpty)
    }

    /// Zero-weight channels neither exclude nor contribute: a candidate
    /// missing the channel ties exactly with one that measures it.
    func testZeroWeightChannelsNeitherExcludeNorContribute() throws {
        let scenario = try scenario("zero-weight-channel-missing")
        let weights = ChannelWeights(parityWeights: scenario.weights)
        let palette = try domainPalette(for: scenario)
        let target = scenario.target.toTarget()

        XCTAssertEqual(weights.weight(for: .blue), 0)
        XCTAssertNil(palette[0].brightness(for: .blue), "Candidate 0 must be missing blue in this corpus")

        guard case .score(let missingScore) = scoreCandidate(palette[0], target, weights),
              case .score(let measuredScore) = scoreCandidate(palette[1], target, weights)
        else {
            return XCTFail("Both candidates must be eligible when blue is unweighted")
        }
        XCTAssertEqual(missingScore, measuredScore, accuracy: 1e-12,
                       "Missing data on an unweighted channel must not change the score")
        XCTAssertEqual(scenario.expected.selectedIndex, 0)
        XCTAssertEqual(scenario.expected.tieBroke, true)
    }

    /// A weight key that is not a canonical light source (`ultraviolet`) is
    /// ignored, yielding the same errors as the equivalent scenario without
    /// it.
    func testUnknownWeightSourceIsIgnored() throws {
        let scenario = try scenario("unknown-weight-ignored")
        XCTAssertTrue(scenario.weights.keys.contains("ultraviolet"))
        XCTAssertEqual(ChannelWeights(parityWeights: scenario.weights),
                       ChannelWeights(parityWeights: try scenario("distinct-errors").weights))

        let reference = try scenario("distinct-errors")
        XCTAssertEqual(scenario.expected.scores.map(\.score), reference.expected.scores.map(\.score))
        XCTAssertEqual(scenario.expected.selectedIndex, reference.expected.selectedIndex)
    }
}
