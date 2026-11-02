import XCTest
@testable import ColorComposerCore

private struct ParityCorpus: Decodable {
    let version: Int
    let cases: [ParityCase]
}

private struct ParityCase: Decodable {
    let id: String
    let description: String?
    let covers: [String]
    let weights: [String: Double]
    let target: [String: Double]
    let candidates: [ParityCandidate]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let id: Int
    let hex: String
    let responses: [String: Double]
}

private struct ParityExpectation: Decodable {
    let selectedID: Int?
    let score: Double?

    enum CodingKeys: String, CodingKey {
        case selectedID = "selected_id"
        case score
    }
}

/// Solver parity harness (issue #39): replays the committed corpus against the
/// Swift `WeightedSquaredErrorScorer` and asserts every expected selection —
/// including tie cases and exclusions — matches exactly, so the client mirrors
/// the Elixir `ColorMatching.WeightedSquaredError` solver contract.
///
/// Corpus: `Tests/Fixtures/solver_parity_corpus.json`
/// Schema and refresh procedure: `docs/solver-parity-corpus.md`
final class SolverParityCorpusTests: XCTestCase {
    private static let requiredCoverage: Set<String> = [
        "tie", "exclusion", "all-excluded", "zero-weight", "weights", "multi-channel"
    ]

    private var corpus: ParityCorpus!

    override func setUp() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver_parity_corpus.json")
        corpus = try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    func testCorpusVersionIsSupported() {
        XCTAssertEqual(
            corpus.version, 1,
            "Unsupported corpus schema version; update this harness together with the corpus (docs/solver-parity-corpus.md)"
        )
    }

    func testCorpusCoversTheRequiredScenarios() {
        let covered = Set(corpus.cases.flatMap(\.covers))
        let missing = Self.requiredCoverage.subtracting(covered).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "Corpus lost required coverage scenarios: \(missing.joined(separator: ", "))"
        )
    }

    func testEveryCandidateIsWellFormedAndIDsAreUniqueWithinACase() {
        for testCase in corpus.cases {
            let ids = testCase.candidates.map(\.id)
            XCTAssertEqual(
                Set(ids).count, ids.count,
                "Case \(testCase.id): candidate ids must be unique for selected_id to be unambiguous"
            )
            for candidate in testCase.candidates {
                XCTAssertNotNil(
                    RGBColor(hex: candidate.hex),
                    "Case \(testCase.id): candidate \(candidate.id) hex '\(candidate.hex)' does not parse"
                )
            }
            for key in testCase.target.keys {
                XCTAssertNotNil(
                    LightingCondition(rawValue: key),
                    "Case \(testCase.id): unknown target lighting condition '\(key)'"
                )
            }
            for candidate in testCase.candidates {
                for key in candidate.responses.keys {
                    XCTAssertNotNil(
                        LightingCondition(rawValue: key),
                        "Case \(testCase.id): candidate \(candidate.id) has unknown lighting condition '\(key)'"
                    )
                }
            }
        }
    }

    /// The core parity assertion: every corpus case must select exactly the
    /// expected candidate at exactly the expected score. `selected_id: null`
    /// means every candidate is excluded and nothing may be selected.
    func testSelectionsMatchExpectedOutputsExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for testCase in corpus.cases {
            let picked = selectBest(in: testCase, scorer: scorer)

            XCTAssertEqual(
                picked?.id, testCase.expected.selectedID,
                "Case \(testCase.id): selection mismatch (\(testCase.description ?? ""))"
            )

            guard let expectedScore = testCase.expected.score else { continue }
            let score = try XCTUnwrap(
                picked?.score,
                "Case \(testCase.id): expected a selected candidate scoring \(expectedScore)"
            )
            XCTAssertEqual(
                score, expectedScore, accuracy: 1e-9,
                "Case \(testCase.id): score mismatch (\(testCase.description ?? ""))"
            )
        }
    }

    // MARK: - Selection (mirrors CompositionSolver semantics)

    /// Scores candidates in list order with the production scorer and keeps
    /// the strictly-lowest score, so ties resolve to the earliest candidate —
    /// the same earliest-wins rule `CompositionSolver` applies per cell.
    private func selectBest(
        in testCase: ParityCase,
        scorer: WeightedSquaredErrorScorer
    ) -> (id: Int, score: Double)? {
        let target = makeTarget(testCase.target, caseID: testCase.id)
        var best: (id: Int, score: Double)?

        for candidate in testCase.candidates {
            guard let color = makeColor(candidate, caseID: testCase.id) else { continue }
            guard case .score(let value) = scorer.score(
                candidate: color, target: target, weights: makeWeights(testCase.weights)
            ) else { continue }
            if value < (best?.score ?? .infinity) {
                best = (candidate.id, value)
            }
        }
        return best
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        func channel(_ key: String) -> Double { values[key] ?? 0 }
        return ChannelWeights(
            white: channel("white"),
            red: channel("red"),
            green: channel("green"),
            blue: channel("blue"),
            lps: channel("lps")
        )
    }

    private func makeTarget(_ values: [String: Double], caseID: String) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in values {
            guard let condition = LightingCondition(rawValue: key) else {
                XCTFail("Case \(caseID): unknown target lighting condition '\(key)'")
                continue
            }
            brightness[condition] = value
        }
        return TargetResponseVector(brightness)
    }

    private func makeColor(_ candidate: ParityCandidate, caseID: String) -> PaletteColor? {
        guard let rgb = RGBColor(hex: candidate.hex) else {
            XCTFail("Case \(caseID): candidate \(candidate.id) hex '\(candidate.hex)' does not parse")
            return nil
        }
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, brightness) in candidate.responses {
            guard let condition = LightingCondition(rawValue: key) else {
                XCTFail("Case \(caseID): candidate \(candidate.id) has unknown lighting condition '\(key)'")
                continue
            }
            responses[condition] = IlluminationResponse(brightness: brightness)
        }
        return PaletteColor(id: candidate.id, hex: candidate.hex, rgb: rgb, responses: responses)
    }
}
