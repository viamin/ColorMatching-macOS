import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the committed `color_matching` solver parity corpus through the
/// app's mirrored scorer and selection policy.
///
/// The corpus is the server's own golden-vector output (viamin/color_matching
/// PR #112): per scenario it records the palette response vectors, the target
/// vector, the channel weights, every candidate's score (with `"excluded"`
/// marking missing-measurement exclusions), the expected selection, the
/// expected error and the tie-break evidence. Replaying it here is what keeps
/// `WeightedSquaredErrorScorer` and the server's `WeightedSquaredError` from
/// silently drifting apart on tie-breaking, exclusions or channel weighting.
final class SolverParityCorpusTests: XCTestCase {
    private var corpus: ParityCorpus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        corpus = try ParityCorpusFixture.load()
    }

    // MARK: - Fixture integrity

    /// The fixture must stay the unmodified upstream corpus: a hand-edited
    /// corpus would make every assertion below vacuous.
    func testCommittedFixtureIsTheUnmodifiedUpstreamCorpus() throws {
        let data = try Data(contentsOf: ParityCorpusFixture.url)

        XCTAssertEqual(
            ParityCorpusFixture.checksum(of: data),
            ParityCorpusFixture.upstreamChecksum,
            "the committed corpus drifted from viamin/color_matching PR #112"
        )
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scenarios.count, 12)
    }

    /// The corpus header describes the very contract the app mirrors: the
    /// server's scorer module, the earliest-wins selection policy, the
    /// missing-measurement policy and the light sources.
    func testCorpusMetadataMatchesTheMirroredServerContract() {
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(
            corpus.missingPolicy,
            "excluded-when-any-positive-weight-channel-missing"
        )
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
    }

    // MARK: - Full replay

    /// Every candidate of every scenario must score exactly as the server
    /// recorded it, and the selection, error and tie evidence must match.
    func testEveryScenarioMatchesTheRecordedScoresSelectionAndTieEvidence() throws {
        for scenario in corpus.scenarios {
            let results = score(scenario)

            assertScores(results, match: scenario.expected, in: scenario.id)
            assertSelection(results, palette: scenario.toPalette(), matches: scenario.expected, in: scenario.id)
        }
    }

    /// The app's own solver — not just the scorer — must pick the candidate
    /// the server picked, ties included.
    func testSolverSelectsTheSameCandidateAsTheServer() throws {
        for scenario in corpus.scenarios {
            let weights = scenario.toChannelWeights()
            let target = scenario.target.toTargetResponseVector()
            let active = weights.activeConditions
            guard active.allSatisfy({ target.value(for: $0) != nil }) else {
                // The server excludes every candidate when the *target* is
                // missing a weighted channel. The solver cannot express that
                // (it needs one source grid per active channel), so that
                // scenario is covered at the scorer level instead.
                continue
            }

            var grids: [LightingCondition: BrightnessGrid] = [:]
            for condition in active {
                grids[condition] = BrightnessGrid(
                    width: 1,
                    height: 1,
                    fill: target.value(for: condition) ?? 0
                )
            }

            let result = try CompositionSolver().solve(
                palette: scenario.toPalette(),
                sourceGrids: grids,
                weights: weights
            )

            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0),
                scenario.expected.selectedIndex,
                "scenario \(scenario.id)"
            )
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, "scenario \(scenario.id)")
            }
        }
    }

    // MARK: - Focused parity rules

    /// Ties are the case the two implementations drift on most easily: the
    /// server keeps the earliest of the tied candidates.
    func testTieScenariosSelectTheEarliestTiedCandidate() throws {
        let tieScenarios = corpus.scenarios.filter { $0.expected.tieBroke == true }
        XCTAssertFalse(tieScenarios.isEmpty, "the corpus must keep tie scenarios")

        for scenario in tieScenarios {
            let selection = try XCTUnwrap(
                earliestBestMatch(score(scenario)),
                "scenario \(scenario.id)"
            )

            XCTAssertGreaterThan(scenario.expected.tiedIndices.count, 1, "scenario \(scenario.id)")
            let firstTied = try XCTUnwrap(
                scenario.expected.tiedIndices.first,
                "scenario \(scenario.id)"
            )
            XCTAssertEqual(selection.index, firstTied, "scenario \(scenario.id)")
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, "scenario \(scenario.id)")
        }
    }

    /// A candidate missing a measurement for any positive-weight channel is
    /// excluded, never scored as if the missing brightness were zero — and it
    /// can never be selected.
    func testCandidatesMissingAWeightedChannelAreExcluded() throws {
        let exclusions = corpus.scenarios.flatMap { scenario in
            scenario.expected.scores.filter { $0.score == .excluded }
        }
        XCTAssertFalse(exclusions.isEmpty, "the corpus must keep exclusion scenarios")

        for scenario in corpus.scenarios {
            let results = score(scenario)
            for expectedScore in scenario.expected.scores where expectedScore.score == .excluded {
                XCTAssertEqual(
                    results[expectedScore.index],
                    .excluded,
                    "scenario \(scenario.id) candidate \(expectedScore.index)"
                )
            }
            if let selectedIndex = scenario.expected.selectedIndex {
                XCTAssertFalse(
                    exclusionsFor(scenario).contains(selectedIndex),
                    "scenario \(scenario.id) selected an excluded candidate"
                )
            }
        }
    }

    /// Channels with weight 0 neither exclude a candidate nor contribute to the
    /// score: a candidate missing an unweighted channel ties exactly with one
    /// whose unweighted value differs wildly.
    func testZeroWeightChannelsNeitherExcludeNorContribute() throws {
        let scenario = try XCTUnwrap(
            corpus.scenarios.first { $0.id == "zero-weight-channel-missing" }
        )
        let results = score(scenario)

        XCTAssertEqual(results[0], .score(0.0625))
        XCTAssertEqual(results[1], .score(0.0625))
        XCTAssertEqual(results[2], .score(0.25))
        XCTAssertEqual(scenario.expected.selectedIndex, 0)
    }

    /// A weight for a light source the app does not know (`ultraviolet`) is
    /// ignored, exactly as the server ignores it, so the scenario scores
    /// identically to the same scenario without the unknown source.
    func testUnknownLightSourceWeightsAreIgnored() throws {
        let withUnknown = try XCTUnwrap(
            corpus.scenarios.first { $0.id == "unknown-weight-ignored" }
        )
        let withoutUnknown = try XCTUnwrap(
            corpus.scenarios.first { $0.id == "distinct-errors" }
        )

        XCTAssertNotNil(withUnknown.weights["ultraviolet"])
        XCTAssertEqual(score(withUnknown), score(withoutUnknown))
    }

    // MARK: - Helpers

    /// The corpus scenario scored by the app's mirrored scorer.
    private func score(_ scenario: ParityScenario) -> [ScorerResult] {
        let target = scenario.target.toTargetResponseVector()
        let weights = scenario.toChannelWeights()
        let palette = scenario.toPalette()
        let scorer = WeightedSquaredErrorScorer()

        return palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
    }

    /// The selection the server recorded: the earliest candidate sharing the
    /// best score.
    private struct Selection {
        let index: Int
        let score: Double
    }

    /// Earliest candidate with the lowest score — the server's
    /// `earliest-index-wins` policy, mirrored by the app's solver.
    private func earliestBestMatch(_ results: [ScorerResult]) -> Selection? {
        var best: Selection?
        for (index, result) in results.enumerated() {
            guard case .score(let score) = result else { continue }
            if let current = best {
                if score < current.score {
                    best = Selection(index: index, score: score)
                }
            } else {
                best = Selection(index: index, score: score)
            }
        }
        return best
    }

    /// Indices of the candidates excluded in `scenario`.
    private func exclusionsFor(_ scenario: ParityScenario) -> [Int] {
        scenario.expected.scores.compactMap { entry in
            entry.score == .excluded ? entry.index : nil
        }
    }

    private func assertScores(
        _ results: [ScorerResult],
        match expected: ParityExpectation,
        in scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            results.count,
            expected.scores.count,
            "scenario \(scenarioID)",
            file: file,
            line: line
        )

        for entry in expected.scores where entry.index < results.count {
            let actual = results[entry.index]
            switch entry.score {
            case .excluded:
                XCTAssertEqual(
                    actual,
                    .excluded,
                    "scenario \(scenarioID) candidate \(entry.index)",
                    file: file,
                    line: line
                )
            case .value(let expectedScore):
                XCTAssertEqual(
                    actual,
                    .score(expectedScore),
                    "scenario \(scenarioID) candidate \(entry.index)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func assertSelection(
        _ results: [ScorerResult],
        palette: [PaletteColor],
        matches expected: ParityExpectation,
        in scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selection = earliestBestMatch(results)

        XCTAssertEqual(
            selection?.index,
            expected.selectedIndex,
            "scenario \(scenarioID)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            selection.map { palette[$0.index].hex },
            expected.selectedHexColor,
            "scenario \(scenarioID)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            selection?.score,
            expected.error,
            "scenario \(scenarioID)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            tiedIndices(results, score: selection?.score),
            expected.tiedIndices,
            "scenario \(scenarioID)",
            file: file,
            line: line
        )

        if expected.selectedIndex == nil {
            XCTAssertNil(expected.tieBroke, "scenario \(scenarioID)", file: file, line: line)
            XCTAssertTrue(expected.tiedIndices.isEmpty, "scenario \(scenarioID)", file: file, line: line)
        } else {
            XCTAssertEqual(
                expected.tieBroke,
                expected.tiedIndices.count > 1,
                "scenario \(scenarioID)",
                file: file,
                line: line
            )
        }
    }

    /// Indices of the candidates sharing `score`.
    private func tiedIndices(_ results: [ScorerResult], score: Double?) -> [Int] {
        guard let score else { return [] }
        return results.enumerated().compactMap { index, result in
            guard case .score(let value) = result, value == score else { return nil }
            return index
        }
    }
}
