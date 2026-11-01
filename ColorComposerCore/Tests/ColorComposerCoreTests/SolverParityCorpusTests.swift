import XCTest
@testable import ColorComposerCore

/// Enforces parity between `WeightedSquaredErrorScorer` and the Elixir
/// `ColorMatching.WeightedSquaredError` solver it mirrors, using the parity
/// corpus committed from `viamin/color_matching#111` (issue #39).
///
/// The corpus is not vendored into this repository yet — that upstream PR is
/// an unmet dependency of issue #39 (see "Dependencies" in the issue body).
/// This test documents the exact contract the vendored corpus must satisfy
/// (location + schema, below) and fails loudly until it is vendored, rather
/// than silently skipping, so the gap stays visible. See also
/// `Fixtures/README.md` in this directory.
final class SolverParityCorpusTests: XCTestCase {
    // MARK: - Corpus schema
    //
    // A JSON array of cases:
    // ```json
    // [
    //   {
    //     "name": "elixir doctest example",
    //     "weights": {"white": 0.5, "red": 1.0, "green": 1.0, "blue": 0.0, "lps": 1.5},
    //     "target": {"white": 0.8, "red": 0.2, "green": 0.7, "blue": 0.1, "lps": 0.5},
    //     "candidates": [
    //       {"id": 1, "responses": {"white": 0.5, "red": 0.1, "green": 0.4, "blue": 0.0, "lps": 0.3}},
    //       {"id": 2, "responses": {"white": 0.1, "red": 0.9}}
    //     ],
    //     "expected_winner_id": 1,
    //     "expected_tied_ids": null,
    //     "expected_excluded_ids": null
    //   }
    // ]
    // ```
    //
    // `expected_winner_id` is `null` when every candidate is excluded.
    // `expected_tied_ids`, when present, lists every candidate id achieving
    // the minimum score — present specifically to pin tie-breaking cases, per
    // issue #39 ("asserts ... selections match expected outputs exactly,
    // including tie cases"). `expected_excluded_ids`, when present, lists
    // candidate ids expected to be `.excluded` (missing a required channel).
    //
    // NOTE: this schema is this app's best-effort anticipation of the
    // corpus color_matching#111 will publish. Reconcile field names against
    // the actual corpus when vendoring it; this file's decode step is the
    // only place that should need to change.

    private struct ParityCandidate: Decodable {
        let id: Int
        let responses: [String: Double]
    }

    private struct ParityCase: Decodable {
        let name: String
        let weights: [String: Double]
        let target: [String: Double]
        let candidates: [ParityCandidate]
        let expectedWinnerId: Int?
        let expectedTiedIds: [Int]?
        let expectedExcludedIds: [Int]?
    }

    private struct CorpusNotVendored: Error, CustomStringConvertible {
        let path: String
        var description: String {
            """
            Solver parity corpus not found at \(path).
            Vendor it from viamin/color_matching#111 (parity corpus) before \
            this test can pass — see Fixtures/README.md in this directory \
            and issue #39.
            """
        }
    }

    private static var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("solver_parity_corpus.json")
    }

    private func loadCorpus() throws -> [ParityCase] {
        let url = Self.corpusURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CorpusNotVendored(path: url.path)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([ParityCase].self, from: Data(contentsOf: url))
    }

    private func weights(from dict: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: dict["white"] ?? 0,
            red: dict["red"] ?? 0,
            green: dict["green"] ?? 0,
            blue: dict["blue"] ?? 0,
            lps: dict["lps"] ?? 0
        )
    }

    private func targetVector(from dict: [String: Double]) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in dict {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    private func color(from candidate: ParityCandidate) -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in candidate.responses {
            guard let condition = LightingCondition(rawValue: key) else { continue }
            responses[condition] = IlluminationResponse(brightness: value)
        }
        return PaletteColor(id: candidate.id, hex: "#000000", rgb: RGBColor(hex: "#000000")!, responses: responses)
    }

    /// For every corpus case, scores all candidates with
    /// `WeightedSquaredErrorScorer` directly (bypassing `CompositionSolver`,
    /// since the corpus pins per-candidate scoring decisions rather than a
    /// grid) and asserts the winner, tie set, and exclusion set match exactly.
    func testScorerMatchesCorpusExpectationsExactly() throws {
        let cases: [ParityCase]
        do {
            cases = try loadCorpus()
        } catch let notVendored as CorpusNotVendored {
            XCTFail(notVendored.description)
            return
        }

        XCTAssertFalse(cases.isEmpty, "Corpus loaded but contained no cases")

        let scorer = WeightedSquaredErrorScorer()

        for parityCase in cases {
            let caseWeights = weights(from: parityCase.weights)
            let target = targetVector(from: parityCase.target)

            var bestScore = Double.infinity
            var bestID: Int?
            var tiedIDs: [Int] = []
            var excludedIDs: [Int] = []

            for candidate in parityCase.candidates {
                let candidateColor = color(from: candidate)
                switch scorer.score(candidate: candidateColor, target: target, weights: caseWeights) {
                case .excluded:
                    excludedIDs.append(candidate.id)
                case .score(let value):
                    if value < bestScore {
                        bestScore = value
                        bestID = candidate.id
                        tiedIDs = [candidate.id]
                    } else if value == bestScore {
                        tiedIDs.append(candidate.id)
                    }
                }
            }

            XCTAssertEqual(
                bestID,
                parityCase.expectedWinnerId,
                "Case \"\(parityCase.name)\": expected winner \(String(describing: parityCase.expectedWinnerId)), got \(String(describing: bestID))"
            )

            if let expectedTied = parityCase.expectedTiedIds {
                XCTAssertEqual(
                    Set(tiedIDs), Set(expectedTied),
                    "Case \"\(parityCase.name)\": tie set mismatch — got \(tiedIDs)"
                )
            }

            if let expectedExcluded = parityCase.expectedExcludedIds {
                XCTAssertEqual(
                    Set(excludedIDs), Set(expectedExcluded),
                    "Case \"\(parityCase.name)\": excluded-candidate set mismatch — got \(excludedIDs)"
                )
            }
        }
    }
}
