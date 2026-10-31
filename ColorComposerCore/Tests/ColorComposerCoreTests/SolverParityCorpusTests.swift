import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the `color_matching` solver parity corpus against
/// `WeightedSquaredErrorScorer` to catch any divergence between this app's
/// mirrored scorer and the Elixir `ColorMatching.WeightedSquaredError` +
/// `ColorMatching.IlluminantMatching` earliest-wins selection it mirrors.
///
/// The fixture (`Fixtures/solver-parity-corpus.v1.json`) is a byte-identical
/// copy of `priv/parity/v1/corpus.json` from `viamin/color_matching` at the
/// commit that merged https://github.com/viamin/color_matching/pull/112
/// (closes viamin/color_matching#111). See the README's "Solver parity
/// corpus" section for how to refresh it after an `algorithm_version` bump.
final class SolverParityCorpusTests: XCTestCase {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/solver-parity-corpus.v1.json")

    private static func loadCorpus() throws -> ParityCorpus {
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: data)
    }

    /// Pins the corpus metadata this test suite was written against. A future
    /// `algorithm_version` bump in `color_matching` must fail this test,
    /// forcing a deliberate corpus refresh instead of silently drifting.
    func testCorpusMetadataMatchesThePinnedAlgorithmVersion() throws {
        let corpus = try Self.loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    func testScorerMatchesEveryCorpusScenarioExactly() throws {
        let corpus = try Self.loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            try assertScenario(scenario, scorer: scorer)
        }
    }

    /// Covers every scenario whose description or id marks it as exercising
    /// tie-breaking, so a regression there is traceable without re-reading
    /// the whole corpus.
    func testTieScenariosBreakTowardTheEarliestIndex() throws {
        let corpus = try Self.loadCorpus()
        let tieScenarios = corpus.scenarios.filter { $0.id.hasPrefix("tie-") }
        XCTAssertFalse(tieScenarios.isEmpty, "Expected the corpus to contain at least one tie scenario")

        for scenario in tieScenarios {
            XCTAssertEqual(scenario.expected.tieBroke, true, "scenario \(scenario.id) should be a tie")
            XCTAssertGreaterThan(
                scenario.expected.tiedIndices.count, 1,
                "scenario \(scenario.id) should record more than one tied index"
            )
            XCTAssertEqual(
                scenario.expected.selectedIndex, scenario.expected.tiedIndices.min(),
                "scenario \(scenario.id) must select the earliest tied index"
            )
        }
    }

    // MARK: - Scenario replay

    private func assertScenario(
        _ scenario: ParityScenario,
        scorer: WeightedSquaredErrorScorer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let weights = Self.channelWeights(from: scenario.weights)
        let target = Self.targetVector(from: scenario.target)
        let candidates = scenario.palette.enumerated().map { index, vector in
            Self.paletteColor(from: vector, id: index)
        }
        let results = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }

        try assertScores(results, expected: scenario.expected.scores, scenarioID: scenario.id, file: file, line: line)

        let (bestIndex, bestScore) = Self.earliestBestScore(results)
        let tiedIndices = Self.tiedIndices(results, bestScore: bestScore)

        XCTAssertEqual(
            bestIndex, scenario.expected.selectedIndex,
            "scenario \(scenario.id): selected index mismatch", file: file, line: line
        )
        XCTAssertEqual(
            tiedIndices, scenario.expected.tiedIndices,
            "scenario \(scenario.id): tied indices mismatch", file: file, line: line
        )
        XCTAssertEqual(
            tiedIndices.count > 1, scenario.expected.tieBroke ?? false,
            "scenario \(scenario.id): tie_broke mismatch", file: file, line: line
        )

        if let bestIndex {
            XCTAssertEqual(
                candidates[bestIndex].hex, scenario.expected.selectedHexColor,
                "scenario \(scenario.id): selected hex color mismatch", file: file, line: line
            )
            let expectedError = try XCTUnwrap(
                scenario.expected.error, "scenario \(scenario.id) selected a candidate but has no expected error",
                file: file, line: line
            )
            XCTAssertEqual(
                bestScore, expectedError, accuracy: 1e-9,
                "scenario \(scenario.id): selected error mismatch", file: file, line: line
            )
        } else {
            XCTAssertNil(scenario.expected.selectedIndex, "scenario \(scenario.id): expected no selection", file: file, line: line)
            XCTAssertNil(scenario.expected.selectedHexColor, "scenario \(scenario.id): expected no selection", file: file, line: line)
            XCTAssertNil(scenario.expected.error, "scenario \(scenario.id): expected no error", file: file, line: line)
        }
    }

    private func assertScores(
        _ results: [ScorerResult],
        expected: [ParityScoreEntry],
        scenarioID: String,
        file: StaticString,
        line: UInt
    ) throws {
        XCTAssertEqual(results.count, expected.count, "scenario \(scenarioID): candidate count mismatch", file: file, line: line)

        for entry in expected {
            guard entry.index < results.count else {
                XCTFail("scenario \(scenarioID): expected score index \(entry.index) out of range", file: file, line: line)
                continue
            }
            switch (results[entry.index], entry.score) {
            case (.excluded, .excluded):
                continue
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(
                    actual, expected, accuracy: 1e-9,
                    "scenario \(scenarioID) index \(entry.index): score mismatch", file: file, line: line
                )
            default:
                XCTFail(
                    "scenario \(scenarioID) index \(entry.index): expected \(entry.score) but got \(results[entry.index])",
                    file: file, line: line
                )
            }
        }
    }

    // MARK: - Corpus → domain conversion

    private static func channelWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private static func targetVector(from vector: ParityVector) -> TargetResponseVector {
        var brightness: [LightingCondition: Double] = [:]
        for (key, value) in vector.channels {
            if let condition = LightingCondition(rawValue: key) {
                brightness[condition] = value
            }
        }
        return TargetResponseVector(brightness)
    }

    private static func paletteColor(from vector: ParityVector, id: Int) -> PaletteColor {
        var responses: [LightingCondition: IlluminationResponse] = [:]
        for (key, value) in vector.channels {
            if let condition = LightingCondition(rawValue: key) {
                responses[condition] = IlluminationResponse(brightness: value)
            }
        }
        return PaletteColor(
            id: id,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor) ?? RGBColor(red: 0, green: 0, blue: 0),
            responses: responses
        )
    }

    /// Lowest score across non-excluded candidates, earliest index wins ties.
    private static func earliestBestScore(_ results: [ScorerResult]) -> (index: Int?, score: Double) {
        var bestIndex: Int?
        var bestScore = Double.infinity
        for (index, result) in results.enumerated() {
            guard case .score(let value) = result, value < bestScore else { continue }
            bestScore = value
            bestIndex = index
        }
        return (bestIndex, bestScore)
    }

    /// Every candidate index whose score exactly equals `bestScore`, in
    /// ascending order — mirrors the Elixir corpus generator's
    /// `tied_indices/2`, which flags ties over *all* candidates, not only the
    /// one ultimately selected.
    private static func tiedIndices(_ results: [ScorerResult], bestScore: Double) -> [Int] {
        guard bestScore.isFinite else { return [] }
        return results.enumerated().compactMap { index, result in
            guard case .score(let value) = result, value == bestScore else { return nil }
            return index
        }
    }
}

// MARK: - Corpus wire model

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let description: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let scores: [ParityScoreEntry]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScoreEntry: Decodable {
    let index: Int
    let score: ParityScoreValue
}

/// The corpus encodes an excluded candidate's score as the string
/// `"excluded"` and every other candidate's as a JSON number.
private enum ParityScoreValue: Decodable, CustomStringConvertible, Equatable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
            return
        }
        let string = try container.decode(String.self)
        guard string == "excluded" else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unexpected parity score value: \(string)"
            )
        }
        self = .excluded
    }

    var description: String {
        switch self {
        case .value(let value): return String(value)
        case .excluded: return "excluded"
        }
    }
}
