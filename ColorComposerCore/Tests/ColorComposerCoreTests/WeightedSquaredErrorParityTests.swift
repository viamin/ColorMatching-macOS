import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    func testReplaysCommittedV1Corpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertFalse(corpus.scenarios.filter(\.expected.tieBroke).isEmpty, "Corpus must retain tie cases")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: Scenario) throws {
        let weights = scenario.weights.channelWeights
        let target = scenario.target.targetVector
        let palette = try scenario.palette.map { try XCTUnwrap($0.paletteColor) }
        let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }

        XCTAssertEqual(results.count, expectedScores.count, scenario.id)
        for (result, expected) in zip(results, expectedScores) {
            switch (result, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .number(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 0, scenario.id)
            default:
                XCTFail("\(scenario.id): score did not match corpus")
            }
        }

        let selected = selectedIndex(results)
        XCTAssertEqual(selected, scenario.expected.selectedIndex, scenario.id)

        if let expectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(palette[expectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(results[expectedIndex].scoreValue, scenario.expected.error, scenario.id)
        }

        let ties = tiedIndices(results, at: scenario.expected.error)
        XCTAssertEqual(ties, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, ties.count > 1, scenario.id)
    }

    private func selectedIndex(_ results: [ScorerResult]) -> Int? {
        results.enumerated().reduce(nil as (index: Int, score: Double)?) { best, entry in
            guard case .score(let score) = entry.element else { return best }
            guard let best else { return (entry.offset, score) }
            return score < best.score ? (entry.offset, score) : best
        }?.index
    }

    private func tiedIndices(_ results: [ScorerResult], at expectedError: Double?) -> [Int] {
        guard let expectedError else { return [] }
        return results.enumerated().compactMap { index, result in
            result.scoreValue == expectedError ? index : nil
        }
    }

    private func loadCorpus() throws -> Corpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: file))
    }
}

private extension ScorerResult {
    var scoreValue: Double? {
        guard case .score(let value) = self else { return nil }
        return value
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]
    let scorer: String
    let selection: String
}

private struct Scenario: Decodable {
    let id: String
    let palette: [CorpusVector]
    let target: CorpusVector
    let weights: CorpusChannels
    let expected: Expected
}

private struct CorpusVector: Decodable {
    let channels: CorpusChannels
    let hexColor: String

    var targetVector: TargetResponseVector { TargetResponseVector(channels.values) }

    var paletteColor: PaletteColor? {
        guard let rgb = RGBColor(hex: hexColor) else { return nil }
        return PaletteColor(
            id: 0,
            hex: hexColor,
            rgb: rgb,
            responses: channels.values.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct CorpusChannels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var values: [LightingCondition: Double] {
        [.white: white, .red: red, .green: green, .blue: blue, .lps: lps].compactMapValues { $0 }
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(white: white ?? 0, red: red ?? 0, green: green ?? 0, blue: blue ?? 0, lps: lps ?? 0)
    }
}

private struct Expected: Decodable {
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
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number or excluded")
        }
    }
}
