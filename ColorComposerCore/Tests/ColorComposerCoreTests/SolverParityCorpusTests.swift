import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity corpus consumption (issue #39).
///
/// `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
/// `ColorMatching.WeightedSquaredError` solver so client and server agree on
/// selection. These tests load committed JSON corpora and assert that the
/// scorer — and the solver's selection through `CompositionSolver` — match the
/// expected outputs exactly, including tie cases (earliest candidate wins,
/// mirroring `IlluminantMatching.best_match/4`), exclusions (a candidate
/// missing any required — weight > 0 — condition is unrankable), and weight
/// handling (zero-weight conditions are never required and never contribute).
///
/// Two corpora live in `Tests/Fixtures/parity/` (see
/// `docs/solver-parity-corpus.md`):
///
/// - `seed_corpus.json` — hand-derived from the documented solver semantics;
///   validates this harness itself and pins the parity rules.
/// - `corpus.json` — the canonical corpus exported from the Elixir repository
///   (viamin/color_matching#111). The test below fails until that export is
///   committed here, which is the deliverable this red phase guards.
final class SolverParityCorpusTests: XCTestCase {
    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("parity", isDirectory: true)

    private static let canonicalCorpusURL = fixturesDirectory
        .appendingPathComponent("corpus.json")

    // MARK: - Corpus schema

    private struct ParityCorpus: Decodable {
        struct Meta: Decodable {
            let schema: Int
            let generator: String
            let source: String?
            let notes: String?
        }

        struct Case: Decodable {
            struct Candidate: Decodable {
                let id: Int
                let hex: String?
                let responses: [String: Double]
            }

            let id: String
            let kind: String?
            let description: String?
            let weights: [String: Double]
            let candidates: [Candidate]
            let target: [String: Double]
            let expectedSelection: Int?
            let expectedScore: Double?
            let expectedExcludedIds: [Int]?
        }

        let meta: Meta
        let cases: [Case]
    }

    private enum CorpusError: Error, CustomStringConvertible {
        case unknownLightSource(String, caseID: String)
        case missingTargetValue(String, caseID: String)
        case unparseableHex(String, candidateID: Int, caseID: String)
        case unsupportedSchema(Int)

        var description: String {
            switch self {
            case .unknownLightSource(let key, let caseID):
                return "parity case '\(caseID)': unknown light source key '\(key)' (canonical keys: white, red, green, blue, lps)"
            case .missingTargetValue(let condition, let caseID):
                return "parity case '\(caseID)': target has no value for required condition '\(condition)'"
            case .unparseableHex(let hex, let candidateID, let caseID):
                return "parity case '\(caseID)': candidate \(candidateID) has unparseable hex '\(hex)'"
            case .unsupportedSchema(let schema):
                return "parity corpus declares schema \(schema); this loader supports schema 1 (update the loader when the export format changes)"
            }
        }
    }

    // MARK: - Loading

    private func loadCorpus(at url: URL) throws -> ParityCorpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: try Data(contentsOf: url))
    }

    // MARK: - Corpus → domain conversion

    private func condition(for key: String, caseID: String) throws -> LightingCondition {
        guard let condition = LightingCondition(rawValue: key) else {
            throw CorpusError.unknownLightSource(key, caseID: caseID)
        }
        return condition
    }

    private func channelWeights(_ raw: [String: Double], caseID: String) throws -> ChannelWeights {
        var weights = ChannelWeights()
        for (key, value) in raw {
            switch try condition(for: key, caseID: caseID) {
            case .white: weights.white = value
            case .red: weights.red = value
            case .green: weights.green = value
            case .blue: weights.blue = value
            case .lps: weights.lps = value
            }
        }
        return weights
    }

    private func paletteColor(_ candidate: ParityCorpus.Case.Candidate, caseID: String) throws -> PaletteColor {
        let hex = candidate.hex ?? "#000000"
        guard let rgb = RGBColor(hex: hex) else {
            throw CorpusError.unparseableHex(hex, candidateID: candidate.id, caseID: caseID)
        }
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in candidate.responses {
            responses[try condition(for: key, caseID: caseID)] = IlluminationResponse(brightness: value)
        }
        return PaletteColor(id: candidate.id, hex: hex, rgb: rgb, responses: responses)
    }

    private func targetVector(_ raw: [String: Double], caseID: String) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            brightness[try condition(for: key, caseID: caseID)] = value
        }
        return TargetResponseVector(brightness)
    }

    /// Solves one corpus case as a 1×1 composition through the app's real
    /// solve path, mirroring how a single output cell is matched.
    private func solveCase(_ testCase: ParityCorpus.Case) throws -> CompositionResult {
        let weights = try channelWeights(testCase.weights, caseID: testCase.id)
        let palette = try testCase.candidates.map { try paletteColor($0, caseID: testCase.id) }

        var grids: [LightingCondition: BrightnessGrid] = [:]
        for (condition, _) in weights.activeEntries {
            guard let value = testCase.target[condition.rawValue] else {
                throw CorpusError.missingTargetValue(condition.rawValue, caseID: testCase.id)
            }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
    }

    // MARK: - Parity assertions

    private func assertCorpusParity(
        _ corpus: ParityCorpus,
        corpusLabel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard corpus.meta.schema == 1 else {
            throw CorpusError.unsupportedSchema(corpus.meta.schema)
        }
        XCTAssertFalse(corpus.cases.isEmpty, "\(corpusLabel): corpus has no cases", file: file, line: line)

        for testCase in corpus.cases {
            try assertCaseParity(testCase, corpusLabel: corpusLabel, file: file, line: line)
        }
    }

    /// Asserts one case at both levels the parity contract covers:
    /// scorer-level ranking (scores, exclusions, earliest-wins ties) and the
    /// solver-level selection the app actually renders.
    private func assertCaseParity(
        _ testCase: ParityCorpus.Case,
        corpusLabel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let weights = try channelWeights(testCase.weights, caseID: testCase.id)
        let palette = try testCase.candidates.map { try paletteColor($0, caseID: testCase.id) }
        let target = try targetVector(testCase.target, caseID: testCase.id)
        let scorer = WeightedSquaredErrorScorer()

        // Rank every candidate with the parity scorer itself.
        var excludedIDs: [Int] = []
        var ranked: [(id: Int, index: Int, score: Double)] = []
        for (index, candidate) in palette.enumerated() {
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .excluded:
                excludedIDs.append(candidate.id)
            case .score(let value):
                ranked.append((candidate.id, index, value))
            }
        }
        XCTAssertEqual(
            Set(excludedIDs),
            Set(testCase.expectedExcludedIds ?? []),
            "\(corpusLabel) case '\(testCase.id)': excluded candidate ids",
            file: file, line: line
        )

        // Expected selection: lowest score, earliest candidate on ties.
        var winner: (id: Int, index: Int, score: Double)?
        for entry in ranked {
            if let current = winner {
                if entry.score < current.score { winner = entry }
            } else {
                winner = entry
            }
        }

        if let expected = testCase.expectedSelection {
            XCTAssertTrue(
                palette.contains { $0.id == expected },
                "\(corpusLabel) case '\(testCase.id)': expected_selection \(expected) does not match any candidate id",
                file: file, line: line
            )

            guard let winner else {
                XCTFail("\(corpusLabel) case '\(testCase.id)': expected a selection but every candidate was excluded", file: file, line: line)
                return
            }
            XCTAssertEqual(winner.id, expected, "\(corpusLabel) case '\(testCase.id)': selected candidate", file: file, line: line)

            if let expectedScore = testCase.expectedScore {
                XCTAssertEqual(winner.score, expectedScore, accuracy: 1e-9, "\(corpusLabel) case '\(testCase.id)': winner score", file: file, line: line)
            }

            let result = try solveCase(testCase)
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), winner.index, "\(corpusLabel) case '\(testCase.id)': CompositionSolver selection", file: file, line: line)
            XCTAssertEqual(result.excludedCandidateCount, excludedIDs.count, "\(corpusLabel) case '\(testCase.id)': solver excluded count", file: file, line: line)
        } else {
            XCTAssertTrue(ranked.isEmpty, "\(corpusLabel) case '\(testCase.id)': expected every candidate excluded, but \(ranked) ranked", file: file, line: line)

            let result = try solveCase(testCase)
            XCTAssertNil(result.colorIndex(x: 0, y: 0), "\(corpusLabel) case '\(testCase.id)': cell must stay unmatched", file: file, line: line)
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "\(corpusLabel) case '\(testCase.id)': unmatched cell error must be infinite", file: file, line: line)
        }

        if testCase.kind == "tie" {
            assertTieSharesMinimumScore(testCase, ranked: ranked, winner: winner, corpusLabel: corpusLabel, file: file, line: line)
        }
    }

    private func assertTieSharesMinimumScore(
        _ testCase: ParityCorpus.Case,
        ranked: [(id: Int, index: Int, score: Double)],
        winner: (id: Int, index: Int, score: Double)?,
        corpusLabel: String,
        file: StaticString,
        line: UInt
    ) {
        guard let winner else { return }
        let tied = ranked.filter { abs($0.score - winner.score) <= 1e-12 }
        XCTAssertGreaterThanOrEqual(tied.count, 2, "\(corpusLabel) case '\(testCase.id)': declared tie must have at least two candidates at the minimum score", file: file, line: line)
        XCTAssertEqual(winner.index, tied.map(\.index).min(), "\(corpusLabel) case '\(testCase.id)': tie must resolve to the earliest candidate", file: file, line: line)
    }

    // MARK: - Seed corpus (harness validation; must always pass)

    func testSeedCorpusSelectionsMatchExpectedOutputsExactly() throws {
        let url = Self.fixturesDirectory.appendingPathComponent("seed_corpus.json")
        let corpus = try loadCorpus(at: url)
        try assertCorpusParity(corpus, corpusLabel: "seed corpus")
    }

    // MARK: - Canonical corpus (viamin/color_matching#111)

    /// The canonical parity corpus exported from the Elixir repository must be
    /// committed and green. Until viamin/color_matching#111's export lands at
    /// `Tests/Fixtures/parity/corpus.json`, this fails — that commit is the
    /// deliverable this red phase guards (see docs/solver-parity-corpus.md).
    func testCanonicalCorpusIsCommittedAndPasses() throws {
        let url = Self.canonicalCorpusURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail(
                "Canonical solver parity corpus is not committed at \(url.path). "
                    + "Export it from viamin/color_matching#111 (see docs/solver-parity-corpus.md) "
                    + "and commit it here so solver parity is enforced."
            )
            return
        }
        let corpus = try loadCorpus(at: url)
        try assertCorpusParity(corpus, corpusLabel: "canonical corpus")
    }
}
