import Foundation
import XCTest
@testable import ColorComposerCore

/// Enforces exact parity between `WeightedSquaredErrorScorer` and the Elixir
/// `ColorMatching.WeightedSquaredError` solver, driven by the committed corpus
/// in `Fixtures/parity/solver_parity_corpus.json`. See that directory's README
/// for the corpus schema and refresh procedure.
final class SolverParityCorpusTests: XCTestCase {
    private static let supportedSchemaVersion = 1

    // MARK: - Corpus

    func testCorpusIsPresentAndDecodable() throws {
        let corpus = try Self.loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, Self.supportedSchemaVersion)
        XCTAssertFalse(corpus.cases.isEmpty)
        XCTAssertFalse(corpus.source.isEmpty)
    }

    func testSelectionsMatchCorpusExactlyIncludingTies() throws {
        for parityCase in try Self.loadCorpus().cases {
            try assertScorerParity(parityCase)
        }
    }

    func testSolverSelectionMatchesCorpus() throws {
        for parityCase in try Self.loadCorpus().cases where parityCase.expected.selectedID != nil {
            try assertSolverParity(parityCase)
        }
    }

    func testCorpusCoversTiesExclusionsAndWeightHandling() throws {
        let cases = try Self.loadCorpus().cases
        let kinds = Set(cases.map(\.kind))
        for required in ["tie", "exclusion", "zero-weight", "all-excluded"] {
            XCTAssertTrue(kinds.contains(required), "corpus is missing a '\(required)' case")
        }
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "case ids must be unique")
    }

    // MARK: - Scorer parity

    /// Asserts every corpus expectation against the scorer directly: each
    /// candidate's score or exclusion, the winning selection, and that ties
    /// resolve to the earliest palette entry.
    private func assertScorerParity(_ parityCase: ParityCase) throws {
        let palette = try parityCase.makePalette()
        let scorer = WeightedSquaredErrorScorer()
        let caseID = "case '\(parityCase.id)'"

        let target = try parityCase.makeTarget()
        var winner: (id: Int, score: Double)?
        for color in palette {
            let result = scorer.score(candidate: color, target: target, weights: parityCase.weights.channelWeights)
            if parityCase.expected.excludedIDs.contains(color.id) {
                XCTAssertEqual(result, .excluded, "\(caseID): id \(color.id) must be excluded")
                continue
            }
            guard case .score(let score) = result else {
                return XCTFail("\(caseID): id \(color.id) unexpectedly excluded")
            }
            XCTAssertEqual(score, try parityCase.expected.score(for: color.id), accuracy: 1e-9, "\(caseID): id \(color.id)")
            if score < (winner?.score ?? .infinity) { winner = (color.id, score) }
        }
        XCTAssertEqual(winner?.id, parityCase.expected.selectedID, "\(caseID): selected id")
    }

    /// Cross-checks the corpus selection against the production solver path on
    /// a single-cell grid, so the corpus pins the real selection algorithm
    /// (including earliest-wins tie-breaking), not a test-side re-implementation.
    private func assertSolverParity(_ parityCase: ParityCase) throws {
        let palette = try parityCase.makePalette()
        let weights = parityCase.weights.channelWeights
        let caseID = "case '\(parityCase.id)'"

        var grids: [LightingCondition: BrightnessGrid] = [:]
        for entry in weights.activeEntries {
            let value = try XCTUnwrap(
                parityCase.target[entry.condition.rawValue],
                "\(caseID): target lacks active channel \(entry.condition)"
            )
            grids[entry.condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }

        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        let selectedID = result.colorIndices.compactMap { $0 }.first.map { palette[$0].id }
        XCTAssertEqual(selectedID, parityCase.expected.selectedID, "\(caseID): solver selection")
        if let expectedScore = parityCase.expected.selectedScore, let error = result.errors.first {
            XCTAssertEqual(error, expectedScore, accuracy: 1e-9, "\(caseID): solver error")
        }
        XCTAssertEqual(result.excludedCandidateCount, parityCase.expected.excludedIDs.count, "\(caseID): excluded count")
    }

    // MARK: - Corpus loading

    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/solver_parity_corpus.json")
    }

    private static func loadCorpus(file: StaticString = #filePath, line: UInt = #line) throws -> ParityCorpus {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(ParityCorpus.self, from: try Data(contentsOf: corpusURL))
        } catch {
            XCTFail("parity corpus missing or undecodable at \(corpusURL.path): \(error)", file: file, line: line)
            throw error
        }
    }
}

// MARK: - Corpus wire models

private struct ParityCorpus: Codable {
    let schemaVersion: Int
    let source: String
    let serverRef: String?
    let cases: [ParityCase]
}

private struct ParityCase: Codable {
    let id: String
    let kind: String
    let weights: ParityWeights
    let target: [String: Double]
    let palette: [ParityColor]
    let expected: ParityExpectation

    struct ParityColor: Codable {
        let id: Int
        let hex: String
        let responses: [String: Double]
    }

    func makePalette() throws -> [PaletteColor] {
        try palette.map { color in
            guard let rgb = RGBColor(hex: color.hex) else {
                throw CorpusFixtureError("\(id): id \(color.id) has unparseable hex \(color.hex)")
            }
            return PaletteColor(
                id: color.id,
                hex: color.hex,
                rgb: rgb,
                responses: try Self.brightness(color.responses, caseID: id)
                    .mapValues { IlluminationResponse(brightness: $0) }
            )
        }
    }

    func makeTarget() throws -> TargetResponseVector {
        TargetResponseVector(try Self.brightness(target, caseID: id))
    }

    private static func brightness(_ raw: [String: Double], caseID: String) throws -> [LightingCondition: Double] {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusFixtureError("\(caseID): unknown light source '\(key)'")
            }
            brightness[condition] = value
        }
        return brightness
    }
}

private struct ParityWeights: Codable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var channelWeights: ChannelWeights {
        ChannelWeights(white: white ?? 0, red: red ?? 0, green: green ?? 0, blue: blue ?? 0, lps: lps ?? 0)
    }
}

private struct ParityExpectation: Codable {
    let selectedID: Int?
    let selectedScore: Double?
    let candidateScores: [String: Double]
    let excludedIDs: [Int]

    func score(for id: Int) throws -> Double {
        guard let score = candidateScores[String(id)] else {
            throw CorpusFixtureError("expected.candidate_scores lacks a score for id \(id)")
        }
        return score
    }
}

/// A corpus (or individual case) that cannot be consumed as written; reported
/// as a test failure with the offending case id rather than a raw decode error.
private struct CorpusFixtureError: Error, CustomStringConvertible {
    let description: String

    init(_ message: String) {
        self.description = message
    }
}
