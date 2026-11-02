import XCTest
@testable import ColorComposerCore

/// Replays the `color_matching` solver parity corpus (viamin/color_matching#111)
/// through `WeightedSquaredErrorScorer`, the client-side mirror of the Elixir
/// `ColorMatching.WeightedSquaredError` solver (see `CompositionScorer.swift`).
///
/// Selection is reimplemented here as earliest-index-wins over the scorer's
/// per-candidate output, matching `CompositionSolver.bestCandidate`'s `<`
/// comparison (`bestCandidate` is file-private, so this mirrors it rather than
/// calling it directly) and the corpus's declared `"earliest-index-wins"`
/// policy. A mismatch here means this client's scorer has drifted from the
/// server's, not that the corpus itself disagrees with its own metadata.
final class SolverParityTests: XCTestCase {
    private static let corpus = ParityCorpus.loadFixture()

    func testCorpusDeclaresExpectedScorerAndSelectionPolicy() {
        XCTAssertEqual(Self.corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(Self.corpus.selection, "earliest-index-wins")
        XCTAssertFalse(Self.corpus.scenarios.isEmpty)
    }

    func testEveryScenarioMatchesExpectedScoresAndSelection() {
        let scorer = WeightedSquaredErrorScorer()
        for scenario in Self.corpus.scenarios {
            assertParity(of: scenario, using: scorer)
        }
    }

    // MARK: - Per-scenario assertions

    private func assertParity(
        of scenario: ParityScenario,
        using scorer: WeightedSquaredErrorScorer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let weights = scenario.channelWeights
        let target = scenario.targetVector
        let palette = scenario.paletteColors

        let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        let selection = earliestWinner(among: results)

        assertPerCandidateScores(scenario, results: results, file: file, line: line)
        assertSelection(scenario, palette: palette, selection: selection, file: file, line: line)
        assertTiedIndicesShareWinningScore(scenario, results: results, winningScore: selection?.score, file: file, line: line)
    }

    private func assertPerCandidateScores(
        _ scenario: ParityScenario,
        results: [ScorerResult],
        file: StaticString,
        line: UInt
    ) {
        for entry in scenario.expected.scores {
            let label = "\(scenario.id): candidate \(entry.index)"
            switch entry.score {
            case .excluded:
                XCTAssertEqual(results[entry.index], .excluded, label, file: file, line: line)
            case .value(let expected):
                guard case .score(let actual) = results[entry.index] else {
                    XCTFail("\(label) expected score \(expected) but was excluded", file: file, line: line)
                    continue
                }
                XCTAssertEqual(actual, expected, accuracy: 1e-9, label, file: file, line: line)
            }
        }
    }

    private func assertSelection(
        _ scenario: ParityScenario,
        palette: [PaletteColor],
        selection: (index: Int, score: Double)?,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(selection?.index, scenario.expected.selectedIndex, "\(scenario.id): selected index", file: file, line: line)
        guard let selection = selection else { return }
        XCTAssertEqual(
            palette[selection.index].hex,
            scenario.expected.selectedHexColor,
            "\(scenario.id): selected hex color",
            file: file, line: line
        )
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(selection.score, expectedError, accuracy: 1e-9, "\(scenario.id): selected error", file: file, line: line)
        }
    }

    private func assertTiedIndicesShareWinningScore(
        _ scenario: ParityScenario,
        results: [ScorerResult],
        winningScore: Double?,
        file: StaticString,
        line: UInt
    ) {
        guard let winningScore = winningScore else {
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, "\(scenario.id): no selection but tied indices present", file: file, line: line)
            return
        }
        for tiedIndex in scenario.expected.tiedIndices {
            guard case .score(let value) = results[tiedIndex] else {
                XCTFail("\(scenario.id): tied index \(tiedIndex) expected a score", file: file, line: line)
                continue
            }
            XCTAssertEqual(value, winningScore, accuracy: 1e-9, "\(scenario.id): tied index \(tiedIndex) score", file: file, line: line)
        }
    }

    /// Lowest-error candidate, earliest index wins ties — mirrors
    /// `CompositionSolver.bestCandidate`'s strict `<` comparison.
    private func earliestWinner(among results: [ScorerResult]) -> (index: Int, score: Double)? {
        var best: (index: Int, score: Double)?
        for (index, result) in results.enumerated() {
            guard case .score(let score) = result, score < (best?.score ?? .infinity) else { continue }
            best = (index, score)
        }
        return best
    }
}
