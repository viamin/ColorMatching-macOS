import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus (issue #39).
///
/// `WeightedSquaredErrorScorer` deliberately mirrors the Elixir
/// `ColorMatching.WeightedSquaredError` solver. This suite loads the corpus
/// committed at `Tests/Fixtures/solver_parity_corpus.json` and asserts that
/// selections — not just scores — match the expected outputs exactly,
/// including tie cases (earliest candidate wins), exclusions (a candidate or
/// target missing a measurement for any weight > 0 channel), and weight
/// handling (weight 0 channels are inactive for both scoring and exclusion).
///
/// See `docs/solver-parity-corpus.md` for the corpus format and how to
/// refresh it from viamin/color_matching#111.
final class SolverParityCorpusTests: XCTestCase {
    private static let corpusURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ColorComposerCoreTests/
        .deletingLastPathComponent()  // Tests/
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("solver_parity_corpus.json")

    // MARK: - Corpus wire format

    private struct Corpus: Codable {
        struct Case: Codable {
            struct Candidate: Codable {
                struct Response: Codable {
                    let brightness: Double
                }
                let id: Int
                let hex: String
                let responses: [String: Response]
            }
            let id: String
            let description: String?
            let tags: [String]?
            let weights: [String: Double]
            let target: [String: Double]
            let candidates: [Candidate]
            let expectedSelection: Int?
            let expectedScore: Double?
            let expectedExcludedIds: [Int]?
        }
        let version: Int
        let scorer: String
        let caseCount: Int?
        let cases: [Case]
    }

    private enum CorpusError: Error, CustomStringConvertible {
        case unreadable(URL, underlying: String)
        case unknownCondition(String, in caseID: String)
        case missingFixtures(String)

        var description: String {
            switch self {
            case .unreadable(let url, let underlying):
                return "Cannot read corpus at \(url.path): \(underlying)"
            case .unknownCondition(let key, let caseID):
                return "Case '\(caseID)' uses non-canonical light source '\(key)'"
            case .missingFixtures(let path):
                return "Corpus fixture missing at \(path) — the corpus must be committed with the tests"
            }
        }
    }

    // MARK: - Loading

    private func loadCorpus() throws -> Corpus {
        let url = Self.corpusURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CorpusError.missingFixtures(url.path)
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(Corpus.self, from: Data(contentsOf: url))
        } catch {
            throw CorpusError.unreadable(url, underlying: String(describing: error))
        }
    }

    // MARK: - Corpus → domain conversion

    private func channelWeights(_ raw: [String: Double], caseID: String) throws -> ChannelWeights {
        for key in raw.keys where LightingCondition(rawValue: key) == nil {
            throw CorpusError.unknownCondition(key, in: caseID)
        }
        func value(_ condition: LightingCondition) -> Double { raw[condition.rawValue] ?? 0 }
        return ChannelWeights(
            white: value(.white), red: value(.red), green: value(.green),
            blue: value(.blue), lps: value(.lps)
        )
    }

    private func targetVector(_ raw: [String: Double], caseID: String) throws -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in raw {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusError.unknownCondition(key, in: caseID)
            }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    private func palette(_ candidates: [Corpus.Case.Candidate]) -> [PaletteColor] {
        candidates.map { candidate in
            var responses: [LightingCondition: IlluminationResponse] = [:]
            for (key, response) in candidate.responses {
                guard let condition = LightingCondition(rawValue: key) else { continue }
                responses[condition] = IlluminationResponse(brightness: response.brightness)
            }
            return PaletteColor(
                id: candidate.id,
                hex: candidate.hex,
                rgb: RGBColor(hex: candidate.hex) ?? RGBColor(red: 0, green: 0, blue: 0),
                responses: responses
            )
        }
    }

    /// One corpus case converted for the scorer.
    private struct PreparedCase {
        let id: String
        let tags: [String]
        let candidates: [PaletteColor]
        let target: TargetResponseVector
        let weights: ChannelWeights
        let expectedSelection: Int?
        let expectedScore: Double?
        let expectedExcludedIds: Set<Int>
    }

    private func prepare(_ corpusCase: Corpus.Case) throws -> PreparedCase {
        PreparedCase(
            id: corpusCase.id,
            tags: corpusCase.tags ?? [],
            candidates: palette(corpusCase.candidates),
            target: try targetVector(corpusCase.target, caseID: corpusCase.id),
            weights: try channelWeights(corpusCase.weights, caseID: corpusCase.id),
            expectedSelection: corpusCase.expectedSelection,
            expectedScore: corpusCase.expectedScore,
            expectedExcludedIds: Set(corpusCase.expectedExcludedIds ?? [])
        )
    }

    // MARK: - Selection under test (mirrors IlluminantMatching.best_match/4)

    /// Score every candidate with `WeightedSquaredErrorScorer`, select the
    /// strictly-lowest score (earliest candidate wins exact ties), exactly as
    /// `CompositionSolver` does. `nil` winner means every candidate was excluded.
    private func scoreCandidates(
        _ candidates: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (scores: [Int: Double], winnerID: Int?, winnerScore: Double?) {
        let scorer = WeightedSquaredErrorScorer()
        var scores: [Int: Double] = [:]
        var winnerID: Int?
        var winnerScore: Double?

        for candidate in candidates {
            switch scorer.score(candidate: candidate, target: target, weights: weights) {
            case .excluded:
                continue
            case .score(let value):
                scores[candidate.id] = value
                if winnerScore == nil || value < winnerScore! {
                    winnerScore = value
                    winnerID = candidate.id
                }
            }
        }
        return (scores, winnerID, winnerScore)
    }

    // MARK: - Tests

    func testCorpusIsWellFormedAndCommitted() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.version, 1, "Unsupported corpus version — update the loader")
        XCTAssertEqual(corpus.scorer, "weighted_squared_error")
        XCTAssertFalse(corpus.cases.isEmpty, "Parity corpus must contain at least one case")
        if let declared = corpus.caseCount {
            XCTAssertEqual(declared, corpus.cases.count, "case_count disagrees with the committed cases")
        }
    }

    /// The core parity assertion: every corpus case must select the expected
    /// candidate exactly, with the expected winning score and exclusions.
    func testSelectionsMatchExpectedOutputsExactly() throws {
        let corpus = try loadCorpus()

        for corpusCase in corpus.cases {
            let prepared = try prepare(corpusCase)
            let (scores, winnerID, winnerScore) = scoreCandidates(
                prepared.candidates, target: prepared.target, weights: prepared.weights
            )

            XCTAssertEqual(
                winnerID, prepared.expectedSelection,
                "Case '\(prepared.id)': selection mismatch"
            )
            if let expectedScore = prepared.expectedScore, let actualScore = winnerScore {
                XCTAssertEqual(
                    actualScore, expectedScore, accuracy: 1e-9,
                    "Case '\(prepared.id)': winning score mismatch"
                )
            }
            let excludedIDs = Set(prepared.candidates.map(\.id)).subtracting(scores.keys)
            XCTAssertEqual(
                excludedIDs, prepared.expectedExcludedIds,
                "Case '\(prepared.id)': excluded candidates mismatch"
            )
        }
    }

    /// Tie cases: at least two candidates share the winner's score bitwise
    /// (so the tie is exact in IEEE 754 arithmetic, not merely close), and the
    /// earliest of them must win.
    func testTieCasesSelectTheEarliestBitwiseEqualCandidate() throws {
        let corpus = try loadCorpus()
        let tieCases = corpus.cases.filter { ($0.tags ?? []).contains("tie") }

        XCTAssertGreaterThanOrEqual(tieCases.count, 3, "Corpus must keep its tie coverage")

        for corpusCase in tieCases {
            let prepared = try prepare(corpusCase)
            let (scores, winnerID, winnerScore) = scoreCandidates(
                prepared.candidates, target: prepared.target, weights: prepared.weights
            )
            let winner = try XCTUnwrap(winnerID, "Tie case '\(prepared.id)' produced no winner")
            let winningScore = try XCTUnwrap(winnerScore)

            let tiedIDs = prepared.candidates
                .filter { scores[$0.id] == winningScore }
                .map(\.id)
            XCTAssertGreaterThanOrEqual(tiedIDs.count, 2, "Case '\(prepared.id)' is not an exact tie")
            XCTAssertEqual(
                tiedIDs.min(), winner,
                "Case '\(prepared.id)': earliest tied candidate must win"
            )
        }
    }

    /// Exclusion cases: a candidate (or the whole target) missing a
    /// measurement for any weight > 0 channel is excluded — never treated as
    /// zero brightness — and an excluded would-be winner is not selected.
    func testExclusionCasesMatchElixirExclusionSemantics() throws {
        let corpus = try loadCorpus()
        let exclusionCases = corpus.cases.filter { ($0.tags ?? []).contains("exclusion") }

        XCTAssertGreaterThanOrEqual(exclusionCases.count, 3, "Corpus must keep its exclusion coverage")

        for corpusCase in exclusionCases {
            let prepared = try prepare(corpusCase)
            let (scores, winnerID, _) = scoreCandidates(
                prepared.candidates, target: prepared.target, weights: prepared.weights
            )

            let excludedIDs = Set(prepared.candidates.map(\.id)).subtracting(scores.keys)
            XCTAssertEqual(
                excludedIDs, prepared.expectedExcludedIds,
                "Case '\(prepared.id)': excluded set mismatch"
            )
            if let winner = winnerID {
                XCTAssertFalse(
                    excludedIDs.contains(winner),
                    "Case '\(prepared.id)': an excluded candidate was selected"
                )
            }
        }
    }

    /// Weight handling: a weight of 0 deactivates a channel entirely — it
    /// contributes nothing to the score and its absence excludes nobody —
    /// while a large weight can flip the selection away from the equal-weight
    /// winner.
    func testWeightHandlingMatchesElixirWeightSemantics() throws {
        let corpus = try loadCorpus()
        let weightCases = corpus.cases.filter { ($0.tags ?? []).contains("weight-handling") }

        XCTAssertGreaterThanOrEqual(weightCases.count, 3, "Corpus must keep its weight-handling coverage")

        for corpusCase in weightCases {
            let prepared = try prepare(corpusCase)
            let (_, winnerID, winnerScore) = scoreCandidates(
                prepared.candidates, target: prepared.target, weights: prepared.weights
            )

            XCTAssertEqual(
                winnerID, prepared.expectedSelection,
                "Case '\(prepared.id)': weight handling changed the selection"
            )
            if let expectedScore = prepared.expectedScore, let actualScore = winnerScore {
                XCTAssertEqual(
                    actualScore, expectedScore, accuracy: 1e-9,
                    "Case '\(prepared.id)': weighted score mismatch"
                )
            }
        }
    }
}
