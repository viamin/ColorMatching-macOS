import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus.
///
/// Loads `Tests/Fixtures/solver_parity_corpus.json` and asserts that
/// `WeightedSquaredErrorScorer` (the Swift mirror of the Elixir
/// `WeightedSquaredError` solver) reproduces the corpus selections exactly:
/// selected color id, winning error (tolerance 1e-12), excluded candidates,
/// and earliest-candidate tie-breaking. Every case whose target defines all
/// active conditions is additionally cross-checked through `CompositionSolver`
/// on a 1x1 grid, so the solver's optimized fast path is held to the same
/// contract. See `docs/solver-parity-corpus.md` for the corpus schema and the
/// refresh procedure (canonical corpus: viamin/color_matching#111).
final class SolverParityCorpusTests: XCTestCase {
    private static let errorAccuracy = 1e-12

    // MARK: - Corpus wire format (schema v1)

    private struct Corpus: Codable {
        let version: Int
        let solver: String
        let tieBreak: String
        let cases: [CorpusCase]
    }

    private struct CorpusCase: Codable {
        let name: String
        let description: String?
        let tags: [String]?
        let weights: CorpusWeights
        let target: [String: Double]
        let palette: [CorpusColor]
        let expected: CorpusExpectation
    }

    private struct CorpusWeights: Codable {
        var white: Double?
        var red: Double?
        var green: Double?
        var blue: Double?
        var lps: Double?
    }

    private struct CorpusColor: Codable {
        let id: Int
        let hex: String
        let responses: [String: Double]
    }

    private struct CorpusExpectation: Codable {
        let selectedId: Int?
        let error: Double?
        let excludedIds: [Int]
    }

    // MARK: - Corpus loading

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)     // .../Tests/ColorComposerCoreTests
            .deletingLastPathComponent()
            .deletingLastPathComponent()              // .../Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("solver_parity_corpus.json")

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Corpus.self, from: data)
        } catch {
            XCTFail("parity corpus missing or undecodable at \(url.path) — see docs/solver-parity-corpus.md: \(error)", file: file, line: line)
            throw error
        }
    }

    func testCorpusMetadataIsValid() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.version, 1, "schema version the loader supports")
        XCTAssertEqual(corpus.solver, "WeightedSquaredError")
        XCTAssertEqual(corpus.tieBreak, "earliest_candidate")
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 8, "a credible parity corpus is broader than a handful of cases")

        let names = corpus.cases.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "case names must be unique")

        for case_ in corpus.cases {
            XCTAssertFalse(case_.palette.isEmpty, "case '\(case_.name)': palette must be non-empty")
            XCTAssertFalse(
                case_.expected.selectedId == nil && case_.expected.error != nil,
                "case '\(case_.name)': an error expectation requires a selected_id"
            )
        }
    }

    func testCorpusCoversTiesExclusionsAndWeightHandling() throws {
        let corpus = try loadCorpus()
        let tagged = { (tag: String) in corpus.cases.filter { $0.tags?.contains(tag) == true } }

        XCTAssertGreaterThanOrEqual(tagged("tie").count, 2, "tie-breaking must be exercised by at least two cases")
        XCTAssertGreaterThanOrEqual(tagged("exclusion").count, 2, "exclusion must be exercised by at least two cases")
        XCTAssertGreaterThanOrEqual(tagged("weights").count, 2, "weight handling must be exercised by at least two cases")
    }

    // MARK: - Scorer parity

    func testScorerSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for case_ in corpus.cases {
            let palette = try makePalette(case_)
            let target = try makeTarget(case_)
            let weights = makeWeights(case_)
            let outcome = select(scorer: scorer, palette: palette, target: target, weights: weights)
            let expected = case_.expected
            let label = "case '\(case_.name)'"

            XCTAssertEqual(outcome.excludedIds, expected.excludedIds, "\(label): excluded candidate ids")

            if let selectedId = expected.selectedId {
                let winner = try XCTUnwrap(outcome.winner, "\(label): expected a selection but every candidate was excluded")
                XCTAssertEqual(winner.id, selectedId, "\(label): selected candidate id")
                let expectedError = try XCTUnwrap(expected.error, "\(label): selected cases must carry an expected error")
                XCTAssertEqual(winner.score, expectedError, accuracy: Self.errorAccuracy, "\(label): winning error")

                if case_.tags?.contains("tie") == true {
                    let tiedCount = outcome.ranked.filter { $0.score == winner.score }.count
                    XCTAssertGreaterThanOrEqual(tiedCount, 2, "\(label): tagged as a tie but only one candidate holds the winning score")
                }
            } else {
                XCTAssertNil(outcome.winner, "\(label): expected no selection but one was made")
                XCTAssertNil(expected.error, "\(label): no-selection cases must not carry an expected error")
                XCTAssertEqual(
                    Set(outcome.excludedIds), Set(palette.map(\.id)),
                    "\(label): no selection requires every candidate to be excluded"
                )
            }
        }
    }

    func testAnchorCaseReproducesElixirDoctestValue() throws {
        let corpus = try loadCorpus()
        let anchor = try XCTUnwrap(corpus.cases.first { $0.name == "elixir_doctest_anchor" })

        let palette = try makePalette(anchor)
        let target = try makeTarget(anchor)
        let candidate = try XCTUnwrap(palette.first { $0.id == anchor.expected.selectedId })

        let result = WeightedSquaredErrorScorer().score(
            candidate: candidate,
            target: target,
            weights: makeWeights(anchor)
        )

        guard case .score(let value) = result else {
            return XCTFail("anchor candidate must be rankable, received .excluded")
        }
        XCTAssertEqual(value, 0.205, accuracy: Self.errorAccuracy, "the Elixir WeightedSquaredError doctest expects 0.205")
    }

    // MARK: - Solver parity (1x1 grid cross-check)

    func testSolverSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()
        let solver = CompositionSolver()   // default WeightedSquaredErrorScorer -> fast path

        for case_ in corpus.cases {
            let weights = makeWeights(case_)
            let active = weights.activeEntries

            // The solver always derives targets from source grids, so a target
            // missing an active condition (scorer-level exclusion) has no
            // solver-level equivalent; those cases are scorer-only by design.
            let targetIsComplete = active.allSatisfy { makeTarget(case_).value(for: $0.condition) != nil }
            guard targetIsComplete else { continue }

            let label = "case '\(case_.name)'"
            let palette = try makePalette(case_)
            var grids: [LightingCondition: BrightnessGrid] = [:]
            let target = try makeTarget(case_)
            for (condition, _) in active {
                grids[condition] = BrightnessGrid(
                    width: 1, height: 1,
                    fill: try XCTUnwrap(target.value(for: condition), "\(label): grid fill value")
                )
            }

            let result: CompositionResult
            do {
                result = try solver.solve(palette: palette, sourceGrids: grids, weights: weights)
            } catch {
                XCTFail("\(label): solver threw \(error)")
                continue
            }

            XCTAssertEqual(result.excludedCandidateCount, case_.expected.excludedIds.count, "\(label): excluded candidate count")

            if let selectedId = case_.expected.selectedId {
                let index = try XCTUnwrap(result.colorIndices[0], "\(label): expected a matched cell")
                XCTAssertEqual(result.palette[index].id, selectedId, "\(label): solver selected candidate id")
                XCTAssertEqual(result.errors[0], try XCTUnwrap(case_.expected.error), accuracy: Self.errorAccuracy, "\(label): solver cell error")
                XCTAssertEqual(result.unmatchedCellCount, 0, "\(label): expected no unmatched cells")
            } else {
                XCTAssertNil(result.colorIndices[0], "\(label): expected an unmatched cell")
                XCTAssertEqual(result.errors[0], Double.infinity, "\(label): unmatched cells use infinite error")
                XCTAssertEqual(result.unmatchedCellCount, 1, "\(label): expected exactly one unmatched cell")
            }
        }
    }

    // MARK: - Domain construction

    private func makeWeights(_ case_: CorpusCase) -> ChannelWeights {
        ChannelWeights(
            white: case_.weights.white ?? 0,
            red: case_.weights.red ?? 0,
            green: case_.weights.green ?? 0,
            blue: case_.weights.blue ?? 0,
            lps: case_.weights.lps ?? 0
        )
    }

    private func makeTarget(_ case_: CorpusCase, file: StaticString = #filePath, line: UInt = #line) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in case_.target {
            guard let condition = LightingCondition(rawValue: key) else {
                XCTFail("case '\(case_.name)': unknown lighting condition '\(key)' in target", file: file, line: line)
                continue
            }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    private func makePalette(_ case_: CorpusCase, file: StaticString = #filePath, line: UInt = #line) throws -> [PaletteColor] {
        try case_.palette.map { entry in
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, value) in entry.responses {
                guard let condition = LightingCondition(rawValue: key) else {
                    XCTFail("case '\(case_.name)': unknown lighting condition '\(key)' in color \(entry.id)", file: file, line: line)
                    continue
                }
                responses[condition] = IlluminationResponse(brightness: value)
            }
            let rgb = try XCTUnwrap(RGBColor(hex: entry.hex), "case '\(case_.name)': color \(entry.id) has invalid hex \(entry.hex)", file: file, line: line)
            return PaletteColor(id: entry.id, hex: entry.hex, rgb: rgb, responses: responses)
        }
    }

    // MARK: - Selection (mirrors IlluminantMatching.best_match: min score, earliest candidate wins)

    private struct SelectionOutcome {
        var winner: (id: Int, score: Double)?
        var excludedIds: [Int] = []
        var ranked: [(id: Int, score: Double)] = []
    }

    private func select(
        scorer: WeightedSquaredErrorScorer,
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> SelectionOutcome {
        var outcome = SelectionOutcome()
        for color in palette {
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .excluded:
                outcome.excludedIds.append(color.id)
            case .score(let score):
                outcome.ranked.append((color.id, score))
                if outcome.winner == nil || score < outcome.winner!.score {
                    outcome.winner = (color.id, score)
                }
            }
        }
        return outcome
    }
}
