import Foundation
import XCTest
@testable import ColorComposerCore

/// Solver parity against the committed corpus (issue #39).
///
/// Loads `Fixtures/weighted_squared_error_parity_corpus.json` — expected
/// outputs derived from the Elixir `ColorMatching.WeightedSquaredError`
/// semantics — and asserts that `WeightedSquaredErrorScorer` reproduces them
/// exactly: score values, selections under the `IlluminantMatching.best_match/4`
/// policy (lowest score wins, earliest candidate wins ties, missing
/// measurements exclude), and the production selection path through
/// `CompositionSolver`'s fast path.
///
/// The corpus lives with the tests so `swift test` enforces parity on every
/// run; see `docs/parity-corpus.md` for how to refresh it from upstream
/// (viamin/color_matching#111).
final class WeightedSquaredErrorParityTests: XCTestCase {
    private enum CorpusError: Error, CustomStringConvertible {
        case unknownCondition(String)

        var description: String {
            switch self {
            case .unknownCondition(let key): return "Unknown lighting condition key in corpus: \(key)"
            }
        }
    }

    // MARK: - Corpus schema

    private struct Corpus: Codable {
        let version: Int
        let solver: String
        let cases: [CorpusCase]
    }

    private struct CorpusCase: Codable {
        let id: String
        let kind: String
        let description: String?
        let weights: [String: Double]
        let target: [String: Double]
        let palette: [CorpusCandidate]
        let expected: CorpusExpected
    }

    private struct CorpusCandidate: Codable {
        let id: Int
        let responses: [String: Double]?
    }

    private struct CorpusExpected: Codable {
        let selectedColorId: Int?
        let score: Double?
        let excludedColorIds: [Int]?
    }

    // MARK: - Loading

    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_corpus.json")
    }

    private func loadCorpus() throws -> Corpus {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: Self.corpusURL))
    }

    // MARK: - Corpus → domain translation

    private func conditions(_ values: [String: Double]) throws -> [LightingCondition: Double] {
        var mapped: [LightingCondition: Double] = [:]
        for (key, value) in values {
            guard let condition = LightingCondition(rawValue: key) else {
                throw CorpusError.unknownCondition(key)
            }
            mapped[condition] = value
        }
        return mapped
    }

    private func weights(_ values: [String: Double]) throws -> ChannelWeights {
        let mapped = try conditions(values)
        return ChannelWeights(
            white: mapped[.white] ?? 0,
            red: mapped[.red] ?? 0,
            green: mapped[.green] ?? 0,
            blue: mapped[.blue] ?? 0,
            lps: mapped[.lps] ?? 0
        )
    }

    private func palette(_ candidates: [CorpusCandidate]) throws -> [PaletteColor] {
        try candidates.map { candidate in
            let mapped = try conditions(candidate.responses ?? [:])
            let hex = String(format: "#%06x", candidate.id)
            return PaletteColor(
                id: candidate.id,
                hex: hex,
                rgb: RGBColor(hex: hex)!,
                responses: mapped.mapValues { IlluminationResponse(brightness: $0) }
            )
        }
    }

    private func target(_ values: [String: Double]) throws -> TargetResponseVector {
        TargetResponseVector(try conditions(values))
    }

    /// The Elixir `best_match/4` policy the corpus expects: lowest score wins,
    /// strictly-lower replaces (so the earliest candidate wins ties), and
    /// excluded candidates are skipped.
    private func bestMatch(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (id: Int?, score: Double?) {
        let scorer = WeightedSquaredErrorScorer()
        var bestId: Int?
        var bestScore: Double?
        for color in palette {
            guard case .score(let value) = scorer.score(candidate: color, target: target, weights: weights),
                  bestScore == nil || value < bestScore! else { continue }
            bestId = color.id
            bestScore = value
        }
        return (bestId, bestScore)
    }

    // MARK: - Corpus integrity

    func testCorpusLoadsAndCoversTiesExclusionsAndWeightHandling() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.solver, "ColorMatching.WeightedSquaredError")
        XCTAssertGreaterThanOrEqual(corpus.cases.count, 10, "The corpus must stay a meaningful parity sample")

        let kinds = Set(corpus.cases.map(\.kind))
        XCTAssertTrue(kinds.contains("tie"), "Corpus must keep tie cases")
        XCTAssertTrue(kinds.contains("exclusion"), "Corpus must keep exclusion cases")
        XCTAssertTrue(kinds.contains("weights"), "Corpus must keep weight-handling cases")
    }

    // MARK: - Scorer parity (score values + best_match policy)

    func testScorerSelectionsAndScoresMatchCorpusExactly() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let palette = try palette(testCase.palette)
            let weights = try weights(testCase.weights)
            let target = try target(testCase.target)
            let winner = bestMatch(palette: palette, target: target, weights: weights)

            XCTAssertEqual(
                winner.id, testCase.expected.selectedColorId,
                "Case \(testCase.id): selection mismatch against the Elixir corpus"
            )

            if let expectedScore = testCase.expected.score, testCase.expected.selectedColorId != nil {
                let winningScore = try XCTUnwrap(
                    winner.score,
                    "Case \(testCase.id): expected a winner but the scorer selected none"
                )
                XCTAssertEqual(
                    winningScore, expectedScore, accuracy: 1e-12,
                    "Case \(testCase.id): winning score mismatch against the Elixir corpus"
                )
            }

            for excludedID in testCase.expected.excludedColorIds ?? [] {
                let candidate = try XCTUnwrap(
                    palette.first { $0.id == excludedID },
                    "Case \(testCase.id): excluded color \(excludedID) is not in the palette"
                )
                XCTAssertEqual(
                    WeightedSquaredErrorScorer().score(candidate: candidate, target: target, weights: weights),
                    .excluded,
                    "Case \(testCase.id): color \(excludedID) must be excluded (missing a required measurement)"
                )
            }
        }
    }

    // MARK: - Production selection path parity

    /// The same corpus driven through `CompositionSolver`'s optimized fast
    /// path (1×1 grids), so the selection the app actually ships — not just
    /// the scorer in isolation — matches the Elixir output, including
    /// earliest-wins ties and fully-excluded cells.
    func testCompositionSolverFastPathSelectionsMatchCorpus() throws {
        let corpus = try loadCorpus()

        for testCase in corpus.cases {
            let palette = try palette(testCase.palette)
            let weights = try weights(testCase.weights)
            let targetConditions = try conditions(testCase.target)

            for condition in weights.activeConditions {
                XCTAssertNotNil(
                    targetConditions[condition],
                    "Case \(testCase.id): corpus target must cover active condition \(condition.rawValue)"
                )
            }

            let sourceGrids = Dictionary(
                uniqueKeysWithValues: weights.activeConditions.compactMap { condition in
                    targetConditions[condition].map { (condition, BrightnessGrid(width: 1, height: 1, values: [$0])) }
                }
            )
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            let expectedIndex = testCase.expected.selectedColorId.flatMap { expectedID in
                palette.firstIndex { $0.id == expectedID }
            }
            XCTAssertEqual(
                result.colorIndices.first ?? nil, expectedIndex,
                "Case \(testCase.id): solver fast-path selection mismatch against the Elixir corpus"
            )

            if expectedIndex == nil {
                XCTAssertEqual(result.unmatchedCellCount, 1, "Case \(testCase.id): expected an unmatched cell")
                XCTAssertTrue(result.errors[0].isInfinite, "Case \(testCase.id): expected an infinite error")
            }
        }
    }
}
