import XCTest
@testable import ColorComposerCore

/// Enforces parity between `WeightedSquaredErrorScorer` (+ earliest-wins
/// selection) and the golden-vector corpus published by the `color_matching`
/// server (issue #39; corpus from viamin/color_matching#111).
///
/// Every scenario replays the committed fixture — no live server needed — and
/// must reproduce the server's per-candidate scores, exclusion decisions,
/// selection, error, and tie evidence *exactly* (corpus values are dyadic
/// rationals, so scores compare with exact equality — summation order cannot
/// round differently). See `docs/solver-parity-corpus.md`.
final class SolverParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    private func scoreAll(
        _ scenario: ParityCorpus.Scenario
    ) -> [ScorerResult] {
        scenario.paletteColors.map {
            scorer.score(candidate: $0, target: scenario.targetVector, weights: scenario.channelWeights)
        }
    }

    /// Earliest-wins best candidate, mirroring `CompositionSolver`'s
    /// `bestCandidate` and the server's `IlluminantMatching.best_match/3`.
    private func selectBest(
        _ results: [ScorerResult]
    ) -> (index: Int?, score: Double?) {
        var best: (index: Int, score: Double)?
        for (index, result) in results.enumerated() {
            guard case .score(let score) = result, score < (best?.score ?? .infinity) else { continue }
            best = (index, score)
        }
        guard let best else { return (nil, nil) }
        return (best.index, best.score)
    }

    private func tiedIndices(
        _ results: [ScorerResult], atMin minimum: Double
    ) -> [Int] {
        results.indices.compactMap { index in
            guard case .score(let score) = results[index], score == minimum else { return nil }
            return index
        }
    }

    // MARK: - Corpus contract

    /// Guards that the committed fixture describes semantics this client
    /// actually implements; a bump upstream must fail loudly here, not
    /// silently pass with mismatched expectations.
    func testCorpusDeclaresSemanticsThisSuiteUnderstands() throws {
        let corpus = try ParityCorpusFixture.load()

        XCTAssertEqual(
            corpus.algorithmVersion, ParityCorpusFixture.supportedAlgorithmVersion,
            "Corpus algorithm_version moved; refresh the fixture and bump "
                + "ParityCorpusFixture.supportedAlgorithmVersion (docs/solver-parity-corpus.md)."
        )
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertTrue(corpus.scorer.contains("WeightedSquaredError"), "unexpected scorer \(corpus.scorer)")
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    // MARK: - Per-candidate score parity

    /// Scores (including exclusions) must match the server bit-for-bit.
    func testPerCandidateScoresMatchCorpusExactly() throws {
        let corpus = try ParityCorpusFixture.load()

        for scenario in corpus.scenarios {
            XCTAssertEqual(
                scenario.palette.count, scenario.expected.scores.count,
                "scenario \(scenario.id): corpus scores must cover every candidate"
            )
            let results = scoreAll(scenario)
            for (index, result) in results.enumerated() {
                guard let expected = scenario.expected.score(for: index) else {
                    XCTFail("scenario \(scenario.id): no expected score for candidate \(index)")
                    continue
                }
                switch (result, expected) {
                case (.excluded, .excluded):
                    continue
                case (.score(let actual), .score(let expectedTotal)):
                    // Exact equality: corpus values are dyadic, so any
                    // difference is real drift, not rounding.
                    XCTAssertEqual(
                        actual, expectedTotal,
                        "scenario \(scenario.id): candidate \(index) score drifted from server"
                    )
                case (.score(let actual), .excluded):
                    XCTFail("scenario \(scenario.id): candidate \(index) scored \(actual) but server excluded it")
                case (.excluded, .score(let expectedTotal)):
                    XCTFail("scenario \(scenario.id): candidate \(index) excluded but server scored \(expectedTotal)")
                }
            }
        }
    }

    // MARK: - Selection parity

    /// Selected candidate (earliest-wins), its hex color, and the winning
    /// error must match — including the tie scenarios.
    func testSelectionsMatchCorpusExactlyIncludingTies() throws {
        let corpus = try ParityCorpusFixture.load()

        for scenario in corpus.scenarios {
            let (index, error) = selectBest(scoreAll(scenario))
            let expected = scenario.expected

            XCTAssertEqual(index, expected.selectedIndex, "scenario \(scenario.id): selected index")
            if let index {
                XCTAssertEqual(
                    scenario.paletteColors[index].hex, expected.selectedHexColor,
                    "scenario \(scenario.id): selected hex color"
                )
                XCTAssertEqual(error, expected.error, "scenario \(scenario.id): winning error")
            } else {
                XCTAssertNil(expected.selectedHexColor, "scenario \(scenario.id): expected no selection")
                XCTAssertNil(expected.error, "scenario \(scenario.id): expected no error")
            }
        }
    }

    /// Tie evidence (`tie_broke`, `tied_indices`) must match exactly — ties
    /// detected by exact equality, as on the server.
    func testTieEvidenceMatchesCorpus() throws {
        let corpus = try ParityCorpusFixture.load()

        for scenario in corpus.scenarios {
            let (index, error) = selectBest(scoreAll(scenario))
            let expected = scenario.expected

            guard let index, let error else {
                XCTAssertTrue(expected.tiedIndices.isEmpty, "scenario \(scenario.id): expected no ties")
                continue
            }

            let tied = tiedIndices(scoreAll(scenario), atMin: error)
            XCTAssertEqual(tied, expected.tiedIndices, "scenario \(scenario.id): tied indices")
            XCTAssertEqual(
                tied.count > 1, expected.tieBroke ?? false,
                "scenario \(scenario.id): tie_broke evidence"
            )
            XCTAssertEqual(index, tied.first, "scenario \(scenario.id): winner must be the earliest tied index")
        }
    }

    // MARK: - Coverage of the parity dimensions the issue calls out

    func testCorpusCoversTiesExclusionsAndWeightHandling() throws {
        let corpus = try ParityCorpusFixture.load()
        let ids = Set(corpus.scenarios.map(\.id))

        XCTAssertGreaterThanOrEqual(ids.count, 12, "corpus scenario set shrank; refresh per docs")
        XCTAssertTrue(ids.contains("tie-symmetric-around-target"), "tie coverage missing")
        XCTAssertTrue(ids.contains("tie-three-way-on-lps"), "three-way tie coverage missing")
        XCTAssertTrue(ids.contains("missing-candidate-excluded"), "exclusion coverage missing")
        XCTAssertTrue(ids.contains("missing-target-excluded"), "target exclusion coverage missing")
        XCTAssertTrue(ids.contains("zero-weight-channel-missing"), "zero-weight handling missing")
        XCTAssertTrue(ids.contains("unknown-weight-ignored"), "unknown-weight handling missing")
    }
}
