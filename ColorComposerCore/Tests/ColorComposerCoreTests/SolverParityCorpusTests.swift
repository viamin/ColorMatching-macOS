import XCTest
@testable import ColorComposerCore

/// Wire shape of the committed solver parity corpus
/// (`Fixtures/weighted-squared-error-parity-corpus.json`), exported by the
/// `color_matching` Elixir service (viamin/color_matching#111). See
/// `docs/solver-parity-corpus.md` for the schema and refresh procedure.
private struct ParityCorpus: Codable {
    struct Source: Codable {
        let repository: String
        let pullRequest: Int
        let scorer: String
    }

    struct Weights: Codable {
        var white: Double?
        var red: Double?
        var green: Double?
        var blue: Double?
        var lps: Double?
    }

    struct Candidate: Codable {
        let id: Int
        let name: String?
        let responses: [String: Double]
    }

    struct ExpectedScore: Codable {
        let candidateId: Int
        let score: Double?
    }

    struct Expected: Codable {
        let selectedCandidateId: Int?
        let score: Double?
        let tiedCandidateIds: [Int]
        let excludedCandidateIds: [Int]
        let candidateScores: [ExpectedScore]
    }

    struct Case: Codable {
        let id: String
        let description: String
        let weights: Weights
        let target: [String: Double]
        let candidates: [Candidate]
        let expected: Expected
    }

    let schemaVersion: Int
    let source: Source
    let tieBreak: String
    let cases: [Case]
}

/// Enforces solver parity with the Elixir `ColorMatching.WeightedSquaredError`
/// scorer (issue #39): every corpus case must reproduce the upstream expected
/// per-candidate scores, exclusions, and the selected candidate — including
/// tie cases, which resolve to the first candidate in input order, matching
/// `IlluminantMatching.best_match/4`.
final class SolverParityCorpusTests: XCTestCase {
    private static let fixtureName = "weighted-squared-error-parity-corpus.json"

    private var scorer: WeightedSquaredErrorScorer!

    override func setUp() {
        super.setUp()
        scorer = WeightedSquaredErrorScorer()
    }

    // MARK: - Loading

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(Self.fixtureName)")
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    // MARK: - Corpus → domain conversion

    private func channelWeights(_ weights: ParityCorpus.Weights) -> ChannelWeights {
        ChannelWeights(
            white: weights.white ?? 0,
            red: weights.red ?? 0,
            green: weights.green ?? 0,
            blue: weights.blue ?? 0,
            lps: weights.lps ?? 0
        )
    }

    private func targetVector(_ target: [String: Double]) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in target {
            brightness[try condition(key)] = value
        }
        return TargetResponseVector(brightness)
    }

    private func paletteColor(_ candidate: ParityCorpus.Candidate) throws -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in candidate.responses {
            responses[try condition(key)] = IlluminationResponse(brightness: value)
        }
        let hex = String(format: "#%06x", UInt32(clamping: candidate.id))
        return PaletteColor(
            id: candidate.id,
            name: candidate.name,
            hex: hex,
            rgb: RGBColor(hex: hex)!,
            responses: responses
        )
    }

    private func condition(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: key) else {
            XCTFail("Corpus references unknown light source \"\(key)\"", file: file, line: line)
            throw CocoaError(.fileReadCorruptFile)
        }
        return condition
    }

    /// Re-selection harness mirroring `IlluminantMatching.best_match/4`:
    /// lowest score wins, ties break to the earliest candidate in input order,
    /// `nil` when every candidate is excluded.
    private func bestMatch(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (id: Int, score: Double)? {
        var best: (id: Int, score: Double)?
        for color in palette {
            guard case .score(let value) = scorer.score(candidate: color, target: target, weights: weights) else {
                continue
            }
            if best == nil || value < best!.score {
                best = (color.id, value)
            }
        }
        return best
    }

    private func solveSelection(
        _ testCase: ParityCorpus.Case,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CompositionResult {
        let weights = channelWeights(testCase.weights)
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in weights.activeEntries {
            let brightness = try XCTUnwrap(
                testCase.target[condition.rawValue],
                "Case \(testCase.id): target lacks an active-condition measurement",
                file: file, line: line
            )
            grids[condition] = BrightnessGrid(width: 1, height: 1, fill: brightness)
        }
        let palette = try testCase.candidates.map { try paletteColor($0) }
        return try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
    }

    // MARK: - Corpus integrity

    /// A refreshed corpus must stay internally consistent before its parity
    /// assertions mean anything: unique ids, expected blocks that agree with
    /// the candidate list, and canonical light-source keys only.
    func testCorpusIsWellFormed() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.schemaVersion, 1)
        XCTAssertEqual(corpus.source.repository, "viamin/color_matching")
        XCTAssertEqual(corpus.source.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertFalse(corpus.cases.isEmpty)

        var caseIds = Set<String>()
        for testCase in corpus.cases {
            XCTAssertTrue(caseIds.insert(testCase.id).inserted, "Duplicate case id \(testCase.id)")
            try assertWellFormedExpected(testCase)
        }
    }

    private func assertWellFormedExpected(_ testCase: ParityCorpus.Case) throws {
        let candidateIds = testCase.candidates.map(\.id)
        XCTAssertEqual(Set(candidateIds).count, candidateIds.count, "Duplicate candidate ids in \(testCase.id)")
        XCTAssertEqual(
            Set(testCase.expected.candidateScores.map(\.candidateId)),
            Set(candidateIds),
            "Case \(testCase.id): candidate_scores must cover exactly the candidates"
        )

        let orderedScores = testCase.candidates.compactMap { candidate in
            testCase.expected.candidateScores.first { $0.candidateId == candidate.id }
        }
        let excludedIds = orderedScores.filter { $0.score == nil }.map(\.candidateId)
        let scored = orderedScores.compactMap { entry -> (Int, Double)? in
            entry.score.map { (entry.candidateId, $0) }
        }

        XCTAssertEqual(testCase.expected.excludedCandidateIds, excludedIds, "Case \(testCase.id): excluded ids")
        if scored.isEmpty {
            XCTAssertNil(testCase.expected.selectedCandidateId, "Case \(testCase.id): expected no selection")
            XCTAssertNil(testCase.expected.score, "Case \(testCase.id): expected no score")
            XCTAssertTrue(testCase.expected.tiedCandidateIds.isEmpty, "Case \(testCase.id): no ties without a winner")
        } else {
            let minimum = scored.map(\.1).min()!
            let tiedIds = scored.filter { abs($0.1 - minimum) < 1e-12 }.map(\.0)
            XCTAssertEqual(testCase.expected.selectedCandidateId, tiedIds.first, "Case \(testCase.id): selection")
            XCTAssertEqual(testCase.expected.score!, minimum, accuracy: 1e-12, "Case \(testCase.id): winning score")
            XCTAssertEqual(testCase.expected.tiedCandidateIds, tiedIds, "Case \(testCase.id): tied ids")
        }
    }

    /// The corpus must keep covering the behaviors the parity contract cares
    /// about, so an upstream refresh cannot silently drop them.
    func testCorpusCoversTiesExclusionsAndWeightHandling() throws {
        let corpus = try loadCorpus()

        XCTAssertTrue(corpus.cases.contains { $0.expected.tiedCandidateIds.count > 1 }, "no tie case")
        XCTAssertTrue(corpus.cases.contains { !$0.expected.excludedCandidateIds.isEmpty }, "no exclusion case")
        XCTAssertTrue(corpus.cases.contains { $0.expected.selectedCandidateId == nil }, "no all-excluded case")
        XCTAssertTrue(
            corpus.cases.contains { testCase in
                let weights = channelWeights(testCase.weights)
                return weights.activeConditions.count < LightingCondition.all.count
                    && !weights.activeConditions.isEmpty
            },
            "no case with an inactive (zero-weight) channel alongside active ones"
        )
        XCTAssertTrue(
            corpus.cases.contains { channelWeights($0.weights).activeConditions.count == LightingCondition.all.count },
            "no case with all five channels active"
        )
    }

    // MARK: - Parity

    /// Every candidate's scorer result must match the corpus expectation:
    /// identical scores, and `.excluded` exactly where upstream excluded.
    func testScorerMatchesCorpusCandidateScoresExactly() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let weights = channelWeights(testCase.weights)
            let target = try targetVector(testCase.target)

            for expected in testCase.expected.candidateScores {
                let candidate = try paletteColor(
                    try XCTUnwrap(
                        testCase.candidates.first { $0.id == expected.candidateId },
                        "Case \(testCase.id): candidate \(expected.candidateId) missing"
                    )
                )
                let result = scorer.score(candidate: candidate, target: target, weights: weights)

                switch (result, expected.score) {
                case (.excluded, nil):
                    continue
                case (.score(let value), let expectedValue?):
                    XCTAssertEqual(
                        value, expectedValue, accuracy: 1e-12,
                        "Case \(testCase.id): candidate \(expected.candidateId) score"
                    )
                default:
                    XCTFail(
                        "Case \(testCase.id): candidate \(expected.candidateId) expected "
                            + "\(String(describing: expected.score)) but received \(result)"
                    )
                }
            }
        }
    }

    /// End-to-end selection parity: the lowest-score candidate must be chosen
    /// exactly, with earliest-candidate tie-breaking, and no selection at all
    /// when the target itself excludes every candidate.
    func testSelectionMatchesCorpusIncludingTieCases() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let weights = channelWeights(testCase.weights)
            let target = try targetVector(testCase.target)
            let palette = try testCase.candidates.map { try paletteColor($0) }
            let match = bestMatch(palette: palette, target: target, weights: weights)

            if let expectedID = testCase.expected.selectedCandidateId {
                let match = try XCTUnwrap(match, "Case \(testCase.id): expected a selection")
                XCTAssertEqual(match.id, expectedID, "Case \(testCase.id): selected candidate")
                XCTAssertEqual(
                    match.score, testCase.expected.score!, accuracy: 1e-12,
                    "Case \(testCase.id): winning score"
                )
                if testCase.expected.tiedCandidateIds.count > 1 {
                    XCTAssertEqual(
                        expectedID, testCase.expected.tiedCandidateIds.first,
                        "Case \(testCase.id): tie must resolve to the earliest candidate"
                    )
                }
            } else {
                XCTAssertNil(match, "Case \(testCase.id): expected no eligible candidate")
            }
        }
    }

    /// The production `CompositionSolver` fast path must agree with the corpus:
    /// same selected color id, same winning error, same excluded count. Cases
    /// whose target lacks a required measurement are scorer-level only (the
    /// solver requires a source grid per active condition).
    func testSolverFastPathSelectionMatchesCorpus() throws {
        let corpus = try loadCorpus()
        let solvable = corpus.cases.filter { $0.expected.selectedCandidateId != nil }

        XCTAssertFalse(solvable.isEmpty)

        for testCase in solvable {
            let result = try solveSelection(testCase)

            let index = try XCTUnwrap(
                result.colorIndex(x: 0, y: 0),
                "Case \(testCase.id): solver left the cell unmatched"
            )
            XCTAssertEqual(
                result.palette[index].id, testCase.expected.selectedCandidateId!,
                "Case \(testCase.id): solver selection"
            )
            XCTAssertEqual(
                result.error(x: 0, y: 0), testCase.expected.score!, accuracy: 1e-12,
                "Case \(testCase.id): solver error"
            )
            XCTAssertEqual(
                result.excludedCandidateCount, testCase.expected.excludedCandidateIds.count,
                "Case \(testCase.id): solver excluded-candidate count"
            )
        }
    }
}
