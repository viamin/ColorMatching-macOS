import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the `color_matching` server's golden-vector corpus against the
/// app's solver, so the two implementations cannot silently drift apart on
/// tie-breaking, missing-measurement exclusion, or channel weighting.
///
/// The corpus is committed at
/// `ColorComposerCore/Tests/ColorComposerCoreTests/Fixtures/parity/v1/corpus.json`
/// — a copy of `priv/parity/v1/corpus.json` in `viamin/color_matching`.
final class SolverParityTests: XCTestCase {
    private var corpus: ParityCorpus!

    override func setUpWithError() throws {
        try super.setUpWithError()
        corpus = try ParityCorpusLoader.load()
    }

    // MARK: - Corpus provenance

    #if canImport(CryptoKit)
    func testCommittedCorpusIsTheUpstreamFixture() throws {
        let data = try ParityCorpusLoader.fixtureData()
        let digest = try XCTUnwrap(
            ParityCorpusLoader.digest(of: data),
            "The corpus digest could not be computed."
        )
        XCTAssertEqual(
            digest,
            ParityCorpusLoader.upstreamDigest,
            "The committed corpus differs from the upstream fixture. Refresh it from "
                + "viamin/color_matching priv/parity/v1/corpus.json and update the digest."
        )
    }
    #endif

    func testCorpusDescribesTheServerSolverContract() {
        XCTAssertEqual(corpus.algorithmVersion, 1, "The corpus algorithm version changed; review every expectation.")
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.isEmpty, "The corpus must contain scenarios.")
    }

    func testCorpusKeepsTieExclusionAndWeightCoverage() {
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.tieBroke == true },
            "The corpus must keep at least one tie scenario."
        )
        XCTAssertTrue(
            corpus.scenarios.contains { scenario in scenario.expected.scores.contains { $0.score == nil } },
            "The corpus must keep at least one missing-measurement exclusion."
        )
        XCTAssertTrue(
            corpus.scenarios.contains { $0.expected.selectedIndex == nil },
            "The corpus must keep at least one scenario where nothing can be selected."
        )
        XCTAssertTrue(
            corpus.scenarios.contains { scenario in scenario.weights.values.contains(0) },
            "The corpus must keep at least one scenario with a zero-weight channel."
        )
    }

    func testCorpusPaletteIndicesAreOrdered() {
        for scenario in corpus.scenarios {
            let indices = scenario.palette.map(\.index)
            XCTAssertEqual(
                indices,
                scenario.palette.indices.map { Optional($0) },
                "Scenario \(scenario.id): palette indices must be 0..<n in order."
            )
            XCTAssertEqual(
                scenario.expected.scores.map(\.index),
                scenario.palette.indices.map { Optional($0) },
                "Scenario \(scenario.id): score table must cover every palette entry in order."
            )
        }
    }

    // MARK: - Scorer parity

    func testEveryCandidateScoreMatchesTheServerCorpus() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let target = scenario.targetVector()
            let weights = scenario.channelWeights()
            let palette = scenario.paletteColors()

            for expected in scenario.expected.scores {
                let candidate = palette[expected.index]
                switch scorer.score(candidate: candidate, target: target, weights: weights) {
                case .excluded:
                    XCTAssertNil(
                        expected.score,
                        "Scenario \(scenario.id): candidate \(expected.index) must be excluded, like the server."
                    )
                case .score(let value):
                    let serverScore = try XCTUnwrap(
                        expected.score,
                        "Scenario \(scenario.id): candidate \(expected.index) must be scored, like the server."
                    )
                    XCTAssertEqual(
                        value,
                        serverScore,
                        "Scenario \(scenario.id): candidate \(expected.index) score differs from the server corpus."
                    )
                }
            }
        }
    }

    func testExclusionsFollowTheMissingMeasurementPolicy() throws {
        for scenario in corpus.scenarios {
            let weights = scenario.channelWeights()
            let targetMissingRequired = weights.activeConditions.contains {
                scenario.target.channels[$0.rawValue] == nil
            }

            for expected in scenario.expected.scores {
                let candidateMissingRequired = weights.activeConditions.contains {
                    scenario.palette[expected.index].channels[$0.rawValue] == nil
                }
                if targetMissingRequired || candidateMissingRequired {
                    XCTAssertNil(
                        expected.score,
                        "Scenario \(scenario.id): candidate \(expected.index) misses a positive-weight channel "
                            + "and must be excluded."
                    )
                } else {
                    XCTAssertNotNil(
                        expected.score,
                        "Scenario \(scenario.id): candidate \(expected.index) measures every positive-weight "
                            + "channel and must be scored."
                    )
                }
            }
        }
    }

    // MARK: - Selection parity

    func testSolverSelectsTheSameColorAsTheServer() throws {
        for scenario in corpus.scenarios {
            guard scenario.targetCoversActiveConditions else {
                // The solver always matches against a complete target, so a
                // scenario whose target is missing a required channel cannot
                // be replayed through it; the scorer assertions cover it.
                continue
            }

            let weights = scenario.channelWeights()
            let palette = scenario.paletteColors()
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: palette,
                sourceGrids: scenario.sourceGrids(),
                weights: weights
            )

            let selected = result.colorIndex(x: 0, y: 0)
            XCTAssertEqual(
                selected,
                scenario.expected.selectedIndex,
                "Scenario \(scenario.id): selection differs from the server corpus."
            )

            if let selected {
                let expectedHex = try XCTUnwrap(
                    scenario.expected.selectedHexColor,
                    "Scenario \(scenario.id): a selection must name the selected color."
                )
                XCTAssertEqual(
                    palette[selected].hex,
                    expectedHex,
                    "Scenario \(scenario.id): the selected color differs from the server corpus."
                )
                let expectedError = try XCTUnwrap(
                    scenario.expected.error,
                    "Scenario \(scenario.id): a selection must record its error."
                )
                XCTAssertEqual(
                    result.error(x: 0, y: 0),
                    expectedError,
                    "Scenario \(scenario.id): the selected color's error differs from the server corpus."
                )
            }

            XCTAssertEqual(
                result.excludedCandidateCount,
                scenario.excludedIndices.count,
                "Scenario \(scenario.id): the number of excluded candidates differs from the server corpus."
            )
        }
    }

    func testTieScenariosSelectTheEarliestTiedCandidate() throws {
        let tieScenarios = corpus.scenarios.filter { $0.expected.tieBroke == true }
        XCTAssertFalse(tieScenarios.isEmpty, "The corpus must keep at least one tie scenario.")

        for scenario in tieScenarios {
            let scored = scenario.expected.scores.filter { $0.score != nil }
            let bestScore = try XCTUnwrap(
                scored.compactMap(\.score).min(),
                "Scenario \(scenario.id): a tie must record the tied score."
            )
            let computedTied = scored.filter { $0.score == bestScore }.map(\.index)

            XCTAssertEqual(
                computedTied,
                scenario.expected.tiedIndices,
                "Scenario \(scenario.id): the tied candidates differ from the server corpus."
            )
            XCTAssertEqual(
                scenario.expected.selectedIndex,
                computedTied.first,
                "Scenario \(scenario.id): the server selects the earliest tied candidate."
            )

            guard scenario.targetCoversActiveConditions else { continue }
            let result = try CompositionSolver(scorer: WeightedSquaredErrorScorer()).solve(
                palette: scenario.paletteColors(),
                sourceGrids: scenario.sourceGrids(),
                weights: scenario.channelWeights()
            )
            XCTAssertEqual(
                result.colorIndex(x: 0, y: 0),
                computedTied.first,
                "Scenario \(scenario.id): the app must select the earliest tied candidate, like the server."
            )
        }
    }
}
