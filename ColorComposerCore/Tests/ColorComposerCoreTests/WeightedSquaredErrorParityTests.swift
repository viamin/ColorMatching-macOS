import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedCorpusMetadataMatchesTheServerContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerReplaysEveryCorpusScenarioExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let weights = channelWeights(from: scenario.weights)
            let target = target(from: scenario.target)
            let candidates = try scenario.palette
                .sorted { $0.index < $1.index }
                .map(paletteColor(from:))
            let scored = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(scored, match: scenario.expected.scores, scenarioID: scenario.id)
            assertSelection(
                selectEarliest(scored),
                candidates: candidates,
                scores: scored,
                expected: scenario.expected,
                scenarioID: scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WeightedSquaredError/v1/corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: file))
    }

    private func channelWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func target(from vector: CorpusVector) -> TargetResponseVector {
        TargetResponseVector(responses(from: vector.channels))
    }

    private func paletteColor(from vector: CorpusVector) throws -> PaletteColor {
        PaletteColor(
            id: vector.index,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        var responses: [LightingCondition: Double] = [:]
        for (name, value) in channels {
            guard let condition = LightingCondition(rawValue: name) else { continue }
            responses[condition] = value
        }
        return responses
    }

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [ExpectedScore],
        scenarioID: String
    ) {
        XCTAssertEqual(actual.count, expected.count, scenarioID)
        for (result, expectedScore) in zip(actual, expected.sorted { $0.index < $1.index }) {
            switch (result, expectedScore.score) {
            case (.excluded, .excluded):
                continue
            case (.score(let actual), .number(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 0, scenarioID)
            default:
                XCTFail("\\(scenarioID): score did not match corpus")
            }
        }
    }

    private func selectEarliest(_ scores: [ScorerResult]) -> (index: Int, score: Double)? {
        var selected: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if selected == nil || score < selected!.score {
                selected = (index, score)
            }
        }
        return selected
    }

    private func assertSelection(
        _ actual: (index: Int, score: Double)?,
        candidates: [PaletteColor],
        scores: [ScorerResult],
        expected: ExpectedSelection,
        scenarioID: String
    ) {
        guard let expectedIndex = expected.selectedIndex else {
            XCTAssertNil(actual, scenarioID)
            XCTAssertTrue(expected.tiedIndices.isEmpty, scenarioID)
            return
        }

        guard let selection = actual else {
            return XCTFail("\\(scenarioID): expected a selection")
        }
        guard let expectedError = expected.error else {
            return XCTFail("\\(scenarioID): selected corpus entry has no expected error")
        }
        XCTAssertEqual(selection.index, expectedIndex, scenarioID)
        XCTAssertEqual(selection.score, expectedError, accuracy: 0, scenarioID)
        XCTAssertEqual(candidates[expectedIndex].hex, expected.selectedHexColor, scenarioID)

        let tiedIndices = scores.indices.filter { index in
            guard case .score(let score) = scores[index] else { return false }
            return score == selection.score
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenarioID)
        XCTAssertEqual(expected.tieBroke, expected.tiedIndices.count > 1, scenarioID)
        XCTAssertEqual(expected.tiedIndices.first, expectedIndex, scenarioID)
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ExpectedSelection
    let id: String
    let palette: [CorpusVector]
    let target: CorpusVector
    let weights: [String: Double]
}

private struct CorpusVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ExpectedSelection: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: ExpectedScoreValue
}

private enum ExpectedScoreValue: Decodable {
    case excluded
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown score value")
        }
    }
}
