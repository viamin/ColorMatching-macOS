import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus (issue #39).
///
/// The corpus mirrors the Elixir `ColorMatching.WeightedSquaredError` solver
/// (viamin/color_matching#111): each case is a palette, a target vector, and
/// channel weights, plus the expected selection, score, exclusions, and tie
/// set. These tests load the corpus from disk and assert that
/// `WeightedSquaredErrorScorer` — both through a direct best-match harness and
/// through `CompositionSolver`'s optimized fast path on a 1×1 grid — selects
/// exactly what the server-side solver would, including tie cases
/// (earliest palette position wins) and exclusion cases (missing measurements
/// are excluded, never read as zero brightness).
///
/// Corpus location and refresh procedure: `docs/solver-parity-corpus.md`.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusFilename = "solver_parity_corpus.json"

    // MARK: - Corpus shape

    func testCorpusFileExistsAndIsValidates() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.version, 1, "Corpus schema version must stay in sync with the decoder")
        XCTAssertEqual(corpus.scorer, "weighted_squared_error")
        XCTAssertFalse(corpus.selectionPolicy.isEmpty)
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 10, "A pruned corpus would silently weaken parity coverage")

        let knownConditions = Set(LightingCondition.allCases.map(\.rawValue))
        let caseIDs = Set(corpus.cases.map(\.id))
        XCTAssertEqual(caseIDs.count, corpus.cases.count, "Case ids must be unique")

        for testCase in corpus.cases {
            let paletteIDs = testCase.palette.map(\.id)
            XCTAssertEqual(Set(paletteIDs).count, paletteIDs.count, "Case \(testCase.id): palette ids must be unique")
            XCTAssertFalse(testCase.palette.isEmpty, "Case \(testCase.id): palette must not be empty")

            XCTAssertTrue(
                testCase.weights.keys.allSatisfy(knownConditions.contains),
                "Case \(testCase.id): unknown lighting condition in weights"
            )
            XCTAssertTrue(
                testCase.weights.values.contains { $0 > 0 },
                "Case \(testCase.id): at least one channel must carry positive weight"
            )
            for entry in testCase.palette {
                XCTAssertTrue(
                    entry.responses.keys.allSatisfy(knownConditions.contains),
                    "Case \(testCase.id), color \(entry.id): unknown lighting condition in responses"
                )
                XCTAssertNotNil(
                    RGBColor(hex: entry.hex),
                    "Case \(testCase.id), color \(entry.id): hex must parse"
                )
            }
            XCTAssertTrue(
                testCase.target.keys.allSatisfy(knownConditions.contains),
                "Case \(testCase.id): unknown lighting condition in target"
            )

            let expected = testCase.expected
            let selectable = Set(paletteIDs)
            if let selectedID = expected.selectedId {
                XCTAssertTrue(selectable.contains(selectedID), "Case \(testCase.id): selected id must exist in palette")
            } else {
                XCTAssertNil(expected.score, "Case \(testCase.id): no selection means no score")
            }
            XCTAssertTrue(
                expected.excludedIds.allSatisfy(selectable.contains),
                "Case \(testCase.id): excluded ids must exist in palette"
            )
            XCTAssertTrue(
                expected.tiedIds.allSatisfy(selectable.contains),
                "Case \(testCase.id): tied ids must exist in palette"
            )
            if !expected.tiedIds.isEmpty {
                if let selectedID = expected.selectedId {
                    XCTAssertTrue(
                        expected.tiedIds.contains(selectedID),
                        "Case \(testCase.id): the winner must be part of the tie set"
                    )
                } else {
                    XCTFail("Case \(testCase.id): a declared tie set requires a winner")
                }
            }
        }
    }

    // MARK: - Scorer selection parity

    func testScorerSelectionsMatchCorpusExactly() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            verifySelection(testCase, file: #filePath, line: #line)
        }
    }

    // MARK: - Solver fast-path parity

    func testSolverFastPathAgreesWithCorpusSelections() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases where testCase.solverCheck ?? true {
            verifySolverAgreement(testCase, file: #filePath, line: #line)
        }
    }

    // MARK: - Loading

    private func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> SolverParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(Self.corpusFilename)

        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            XCTFail("Missing parity corpus at \(fixtureURL.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: fixtureURL))
        } catch {
            XCTFail("Corpus failed to decode: \(error)", file: file, line: line)
            throw error
        }
    }

    // MARK: - Case verification

    /// Replicates the Elixir `best_match/4` selection loop: score every
    /// candidate in palette order with `WeightedSquaredErrorScorer`, keep the
    /// strictly lowest score (ties resolve to the earliest position), and
    /// collect the ids of excluded candidates.
    private func bestMatch(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (selected: PaletteColor?, bestScore: Double?, excluded: [Int], scores: [Int: Double]) {
        let scorer = WeightedSquaredErrorScorer()
        var selected: PaletteColor?
        var bestScore = Double.infinity
        var excluded: [Int] = []
        var scores: [Int: Double] = [:]

        for color in palette {
            switch scorer.score(candidate: color, target: target, weights: weights) {
            case .excluded:
                excluded.append(color.id)
            case .score(let value):
                scores[color.id] = value
                if value < bestScore {
                    bestScore = value
                    selected = color
                }
            }
        }
        return (selected, selected == nil ? nil : bestScore, excluded, scores)
    }

    private func verifySelection(_ testCase: CorpusCase, file: StaticString, line: UInt) {
        let palette = buildPalette(testCase)
        let weights = buildWeights(testCase.weights)
        let target = buildTarget(testCase.target)
        let outcome = bestMatch(palette: palette, target: target, weights: weights)
        let expected = testCase.expected

        XCTAssertEqual(
            outcome.selected?.id,
            expected.selectedId,
            "Case \(testCase.id): selected color mismatch",
            file: file, line: line
        )
        XCTAssertEqual(
            Set(outcome.excluded),
            Set(expected.excludedIds),
            "Case \(testCase.id): excluded candidates mismatch",
            file: file, line: line
        )

        if let expectedScore = expected.score {
            guard let bestScore = outcome.bestScore else {
                XCTFail("Case \(testCase.id): expected score \(expectedScore) but nothing was selectable", file: file, line: line)
                return
            }
            XCTAssertEqual(
                bestScore,
                expectedScore,
                accuracy: 1e-9,
                "Case \(testCase.id): winning score mismatch",
                file: file, line: line
            )
        }

        verifyTieSet(testCase, outcome: outcome, file: file, line: line)
    }

    /// With tied ids declared, every tied candidate must score identically,
    /// the winner must be the earliest tied palette position, and every other
    /// scored candidate must be strictly worse — so the tie set is provably
    /// complete and the earliest-wins policy is exercised.
    private func verifyTieSet(
        _ testCase: CorpusCase,
        outcome: (selected: PaletteColor?, bestScore: Double?, excluded: [Int], scores: [Int: Double]),
        file: StaticString,
        line: UInt
    ) {
        guard let bestScore = outcome.bestScore else { return }
        let tiedSet = Set(testCase.expected.tiedIds)

        for tiedID in tiedSet {
            XCTAssertEqual(
                outcome.scores[tiedID] ?? .nan,
                bestScore,
                accuracy: 1e-12,
                "Case \(testCase.id): tied color \(tiedID) must score exactly like the winner",
                file: file, line: line
            )
        }

        if !tiedSet.isEmpty {
            let earliestTied = testCase.palette.first { tiedSet.contains($0.id) }?.id
            XCTAssertEqual(
                outcome.selected?.id,
                earliestTied,
                "Case \(testCase.id): ties must resolve to the earliest palette position",
                file: file, line: line
            )
        }

        for (candidateID, score) in outcome.scores
        where !tiedSet.contains(candidateID) && candidateID != outcome.selected?.id {
            XCTAssertGreaterThan(
                score,
                bestScore + 1e-12,
                "Case \(testCase.id): color \(candidateID) unexpectedly ties the winner but is not in tied_ids",
                file: file, line: line
            )
        }
    }

    /// `CompositionSolver`'s contiguous fast path must pick the same palette
    /// index as the corpus (and the scorer harness) for the same single-cell
    /// input, including the all-excluded case.
    private func verifySolverAgreement(_ testCase: CorpusCase, file: StaticString, line: UInt) {
        let palette = buildPalette(testCase)
        let weights = buildWeights(testCase.weights)
        let target = buildTarget(testCase.target)

        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in weights.activeEntries {
            guard let brightness = target.value(for: condition) else {
                XCTFail("Case \(testCase.id): target lacks active condition \(condition)", file: file, line: line)
                return
            }
            grids[condition] = BrightnessGrid(width: 1, height: 1, fill: brightness)
        }

        let result: CompositionResult
        do {
            result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        } catch {
            XCTFail("Case \(testCase.id): solver threw \(error)", file: file, line: line)
            return
        }

        let expected = testCase.expected
        XCTAssertEqual(
            result.excludedCandidateCount,
            expected.excludedIds.count,
            "Case \(testCase.id): solver excluded-count mismatch",
            file: file, line: line
        )

        guard let selectedID = expected.selectedId else {
            XCTAssertNil(
                result.colorIndex(x: 0, y: 0),
                "Case \(testCase.id): all candidates excluded, solver must leave the cell unmatched",
                file: file, line: line
            )
            XCTAssertTrue(
                result.error(x: 0, y: 0).isInfinite,
                "Case \(testCase.id): unmatched cell error must be infinite",
                file: file, line: line
            )
            return
        }

        guard let expectedIndex = palette.firstIndex(where: { $0.id == selectedID }) else {
            XCTFail("Case \(testCase.id): selected id \(selectedID) not in palette", file: file, line: line)
            return
        }
        XCTAssertEqual(
            result.colorIndex(x: 0, y: 0),
            expectedIndex,
            "Case \(testCase.id): solver fast path picked a different color than the corpus",
            file: file, line: line
        )
        if let expectedScore = expected.score {
            XCTAssertEqual(
                result.error(x: 0, y: 0),
                expectedScore,
                accuracy: 1e-9,
                "Case \(testCase.id): solver cell error mismatch",
                file: file, line: line
            )
        }
    }

    // MARK: - Corpus-to-domain builders

    private func buildPalette(_ testCase: CorpusCase) -> [PaletteColor] {
        testCase.palette.map { entry in
            let responses = Dictionary(
                uniqueKeysWithValues: entry.responses.map { key, value in
                    (LightingCondition(rawValue: key)!, IlluminationResponse(brightness: value))
                }
            )
            return PaletteColor(
                id: entry.id,
                name: entry.name,
                hex: entry.hex,
                rgb: RGBColor(hex: entry.hex)!,
                responses: responses
            )
        }
    }

    private func buildTarget(_ raw: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(Dictionary(
            uniqueKeysWithValues: raw.map { (LightingCondition(rawValue: $0.key)!, $0.value) }
        ))
    }

    private func buildWeights(_ raw: [String: Double]) -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in raw {
            switch LightingCondition(rawValue: key)! {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            }
        }
        return weights
    }
}

// MARK: - Corpus wire model

private struct SolverParityCorpus: Decodable {
    let version: Int
    let scorer: String
    let source: Source
    let selectionPolicy: String
    let cases: [CorpusCase]

    struct Source: Decodable {
        let repository: String
        let pullRequest: Int?
        let module: String
        let provenance: String
    }

    struct CorpusCase: Decodable {
        let id: String
        let description: String?
        let weights: [String: Double]
        let palette: [Entry]
        let target: [String: Double]
        let expected: Expected
        let solverCheck: Bool?

        struct Entry: Decodable {
            let id: Int
            let name: String?
            let hex: String
            let responses: [String: Double]
        }

        struct Expected: Decodable {
            let selectedId: Int?
            let score: Double?
            let excludedIds: [Int]
            let tiedIds: [Int]
        }
    }
}
