import Foundation
import XCTest
@testable import ColorComposerCore

/// Enforces parity between `WeightedSquaredErrorScorer` and the Elixir
/// `ColorMatching.WeightedSquaredError` solver it mirrors, against the
/// committed corpus published by the server (viamin/color_matching#111).
///
/// The corpus is vendored at `Fixtures/solver_parity_corpus.json` (see
/// `docs/solver-parity-corpus.md` for the schema and refresh instructions).
/// Until that corpus is vendored, this test fails loudly rather than skipping,
/// so a missing/stale corpus is visible in `swift test` output.
final class SolverParityCorpusTests: XCTestCase {
    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver_parity_corpus.json")
    }

    func testWeightedSquaredErrorScorerSelectionsMatchCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertFalse(corpus.cases.isEmpty, "Parity corpus at \(corpusURL.path) has no cases.")

        let scorer = WeightedSquaredErrorScorer()

        for testCase in corpus.cases {
            let weights = testCase.weights.asChannelWeights()
            let target = testCase.target.asTargetResponseVector()
            let candidates = testCase.candidates.map { $0.asPaletteColor() }

            let selection = Self.earliestWinsSelection(
                scorer: scorer, candidates: candidates, target: target, weights: weights
            )

            if let expectedSelectedId = testCase.expectedSelectedId {
                XCTAssertEqual(
                    selection?.id, expectedSelectedId,
                    "Case '\(testCase.name)': expected candidate \(expectedSelectedId) to be selected, got \(String(describing: selection?.id))."
                )
            } else {
                XCTAssertNil(
                    selection,
                    "Case '\(testCase.name)': expected every candidate to be excluded, but \(String(describing: selection?.id)) was selected."
                )
            }

            // Tie cases: every id in `tiedCandidateIds` must score identically to
            // the selection, and the solver's earliest-wins rule must still pick
            // the lowest-indexed tied candidate (matching `CompositionSolver`'s
            // tie-break policy, which this corpus is meant to pin down).
            guard !testCase.tiedCandidateIds.isEmpty, let selectedScore = selection.map({
                Self.score(scorer: scorer, candidate: $0, target: target, weights: weights)
            }) else { continue }

            for tiedId in testCase.tiedCandidateIds {
                guard let tiedCandidate = candidates.first(where: { $0.id == tiedId }) else {
                    XCTFail("Case '\(testCase.name)': tied candidate id \(tiedId) not present among candidates.")
                    continue
                }
                let tiedScore = Self.score(scorer: scorer, candidate: tiedCandidate, target: target, weights: weights)
                XCTAssertEqual(
                    tiedScore, selectedScore, accuracy: 1e-9,
                    "Case '\(testCase.name)': tied candidate \(tiedId) does not score identically to the selection."
                )
            }

            XCTAssertEqual(
                selection?.id, testCase.tiedCandidateIds.min(),
                "Case '\(testCase.name)': earliest-wins tie-break did not select the lowest-id tied candidate."
            )
        }
    }

    // MARK: - Selection (mirrors `CompositionSolver.bestCandidate`'s earliest-wins policy)

    private static func earliestWinsSelection(
        scorer: WeightedSquaredErrorScorer,
        candidates: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> PaletteColor? {
        var best: PaletteColor?
        var bestScore = Double.infinity
        for candidate in candidates {
            guard case .score(let value) = scorer.score(candidate: candidate, target: target, weights: weights) else {
                continue
            }
            if value < bestScore {
                bestScore = value
                best = candidate
            }
        }
        return best
    }

    private static func score(
        scorer: WeightedSquaredErrorScorer,
        candidate: PaletteColor,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> Double {
        guard case .score(let value) = scorer.score(candidate: candidate, target: target, weights: weights) else {
            return .infinity
        }
        return value
    }

    // MARK: - Loading

    private func loadCorpus() throws -> ParityCorpus {
        guard FileManager.default.fileExists(atPath: corpusURL.path) else {
            let message = """
                Solver parity corpus not found at \(corpusURL.path).
                Vendor the committed corpus from viamin/color_matching#111 at that path \
                (see docs/solver-parity-corpus.md for the schema and refresh steps) before this test can run.
                """
            XCTFail(message)
            throw CorpusNotVendored(message: message)
        }
        let data = try Data(contentsOf: corpusURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }
}

private struct CorpusNotVendored: Error {
    let message: String
}

// MARK: - Corpus schema

/// Mirrors the schema documented in `docs/solver-parity-corpus.md`. Weights
/// and brightness vectors are keyed by raw `LightingCondition` strings
/// (`white`/`red`/`green`/`blue`/`lps`) rather than the enum itself, matching
/// how `PaletteColorDTO.toDomain()` already decodes server responses.
private struct ParityCorpus: Decodable {
    let version: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let name: String
    let weights: ChannelVector
    let target: ChannelVector
    let candidates: [ParityCandidate]
    /// `nil` when every candidate is expected to be excluded.
    let expectedSelectedId: Int?
    /// Ids that must score identically to the selection, exercising the
    /// solver's earliest-wins tie-break. Empty when the case has no tie.
    let tiedCandidateIds: [Int]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        weights = try container.decode(ChannelVector.self, forKey: .weights)
        target = try container.decode(ChannelVector.self, forKey: .target)
        candidates = try container.decode([ParityCandidate].self, forKey: .candidates)
        expectedSelectedId = try container.decodeIfPresent(Int.self, forKey: .expectedSelectedId)
        tiedCandidateIds = try container.decodeIfPresent([Int].self, forKey: .tiedCandidateIds) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name, weights, target, candidates, expectedSelectedId, tiedCandidateIds
    }
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: ChannelVector

    func asPaletteColor() -> PaletteColor {
        var responseMap: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in responses.values {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            responseMap[condition] = IlluminationResponse(brightness: value)
        }
        let rgb = RGBColor(hex: hex) ?? RGBColor(red: 0, green: 0, blue: 0)
        return PaletteColor(id: id, hex: hex, rgb: rgb, responses: responseMap)
    }
}

/// A sparse condition → value map, decoded from a `{"white": 0.5, ...}` JSON
/// object keyed by the raw `LightingCondition` strings.
private struct ChannelVector: Decodable {
    let values: [String: Double]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([String: Double].self)
    }

    func asChannelWeights() -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    func asTargetResponseVector() -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in values {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }
}
