import XCTest
@testable import ColorComposerCore

/// Solver parity against the `color_matching` corpus (viamin/color_matching#111).
///
/// Every case runs through `WeightedSquaredErrorScorer` and the full
/// `CompositionSolver` selection path (1×1 grid per target vector) and must
/// reproduce the Elixir `WeightedSquaredError` outcome exactly:
///
/// - **Selection** — the selected palette id equals `expected.selected_id`;
///   `null` expectations leave the cell unmatched.
/// - **Ties** — `tie_ids` lists every id achieving the minimum score, and the
///   selection must be the earliest of them in palette order (the shared
///   earliest-wins policy of `IlluminantMatching.best_match/4`).
/// - **Exclusions** — `excluded_ids` matches, in both directions, the ids the
///   scorer excludes for missing measurements on weight > 0 conditions.
/// - **Scores & weights** — the winner's score equals `expected.score` within
///   1e-9, covering weight scaling (fractional and channel-skewed weights).
///
/// Two corpora are consumed:
///
/// 1. The committed fixture snapshot (`ParityCorpusFixture`) — always present,
///    pins the corpus-format contract and the tie/exclusion semantics.
/// 2. The vendored upstream corpus, loaded from the committed copy in this
///    repository (see `docs/parity-corpus.md`). Its absence fails the test on
///    purpose: parity is enforced, not assumed.
final class SolverParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    // MARK: - Fixture corpus (committed snapshot)

    func testFixtureCorpusSelectionParity() throws {
        let corpus = try ParityCorpusFixture.decode()
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 11, "fixture corpus shrank; cases were lost")
        runSelectionParity(corpus, origin: "fixture snapshot")
    }

    // MARK: - Vendored upstream corpus (viamin/color_matching#111)

    func testVendoredCorpusSelectionParity() throws {
        let corpus: ParityCorpus
        let origin: String
        do {
            let vendored = try ParityCorpus.loadVendored()
            corpus = vendored.corpus
            origin = vendored.origin.path
        } catch {
            XCTFail(
                "The solver parity corpus is not vendored (expected from viamin/color_matching#111): \(error). "
                    + "Commit it and refresh per docs/parity-corpus.md."
            )
            return
        }
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 11, "vendored corpus has fewer cases than the fixture")
        runSelectionParity(corpus, origin: origin)
    }

    // MARK: - Runner

    private func runSelectionParity(_ corpus: ParityCorpus, origin: String) {
        for corpusCase in corpus.cases {
            do {
                assertSelectionParity(try PreparedParityCase(corpusCase), origin: origin)
            } catch {
                XCTFail("[\(origin)] case '\(corpusCase.name)' is invalid: \(error)")
            }
        }
    }

    private func assertSelectionParity(_ testCase: PreparedParityCase, origin: String) {
        let name = "[\(origin)] \(testCase.name)"
        let targetVector = TargetResponseVector(testCase.target)
        let result = solve(testCase)

        // Exclusions must match in both directions: missing a measurement on a
        // weight > 0 condition is the only reason to be excluded.
        var actualExcluded = Set<Int>()
        var rankable: [(id: Int, index: Int, score: Double)] = []
        for (index, color) in testCase.palette.enumerated() {
            switch scorer.score(candidate: color, target: targetVector, weights: testCase.weights) {
            case .excluded:
                actualExcluded.insert(color.id)
            case .score(let value):
                rankable.append((color.id, index, value))
            }
        }
        XCTAssertEqual(
            actualExcluded, testCase.expectedExcludedIDs,
            "\(name): excluded ids must match expected excluded_ids exactly"
        )

        guard let selectedID = testCase.expectedSelectionID else {
            // Nothing is selectable: the solver must leave the cell unmatched.
            XCTAssertTrue(actualExcluded.isSuperset(of: testCase.palette.map(\.id)),
                          "\(name): a null selection requires every candidate to be excluded")
            XCTAssertNil(result?.colorIndex(x: 0, y: 0), "\(name): cell must stay unmatched")
            XCTAssertEqual(result?.unmatchedCellCount, 1, "\(name): one cell, unmatched")
            XCTAssertEqual(result?.excludedCandidateCount, testCase.expectedExcludedIDs.count,
                           "\(name): solver excludedCandidateCount")
            XCTAssertTrue(result?.error(x: 0, y: 0).isInfinite ?? false, "\(name): unmatched error is infinite")
            return
        }

        // Tie set: every id within 1e-12 of the best score. The corpus records
        // the full set; a missing or extra member is a parity break.
        let best = rankable.map(\.score).min() ?? .infinity
        let actualTies = Set(rankable.filter { $0.score <= best + 1e-12 }.map(\.id))
        XCTAssertEqual(actualTies, testCase.expectedTieIDs,
                       "\(name): ids achieving the minimum score must match tie_ids exactly")

        // Earliest-wins: the expected selection must be the first tied id in
        // palette order — the shared best_match/4 tie-breaking policy.
        guard let selectedIndex = testCase.palette.firstIndex(where: { $0.id == selectedID }) else { return }
        let earliestTiedIndex = rankable
            .filter { testCase.expectedTieIDs.contains($0.id) }
            .map(\.index)
            .min()
        XCTAssertEqual(selectedIndex, earliestTiedIndex,
                       "\(name): selection must be the earliest tied candidate in palette order")

        // Full-solver agreement: same selection, same score, same exclusions.
        let chosen: Int? = result.flatMap { solverResult in
            solverResult.colorIndex(x: 0, y: 0).map { solverResult.palette[$0].id }
        }
        XCTAssertEqual(chosen, selectedID, "\(name): solver must select expected id")
        XCTAssertEqual(result?.excludedCandidateCount, testCase.expectedExcludedIDs.count,
                       "\(name): solver excludedCandidateCount")

        guard let expectedScore = testCase.expectedScore else { return }
        XCTAssertEqual(result?.error(x: 0, y: 0) ?? .infinity, expectedScore, accuracy: 1e-9,
                       "\(name): solver cell error must equal expected score")
        if case .score(let scorerScore) = scorer.score(candidate: testCase.palette[selectedIndex],
                                                       target: targetVector,
                                                       weights: testCase.weights) {
            XCTAssertEqual(scorerScore, expectedScore, accuracy: 1e-9,
                           "\(name): scorer must reproduce the expected score")
        }
    }

    /// Runs the case's target vector through the solver as a 1×1 composition.
    private func solve(_ testCase: PreparedParityCase) -> CompositionResult? {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, value) in testCase.target {
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return try? CompositionSolver(scorer: WeightedSquaredErrorScorer())
            .solve(palette: testCase.palette, sourceGrids: grids, weights: testCase.weights)
    }
}
