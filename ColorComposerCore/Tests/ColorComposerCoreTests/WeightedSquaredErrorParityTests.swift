import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysCommittedV1CorpusExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = channelWeights(from: scenario.weights)
        let target = targetVector(from: scenario.target)
        let palette = try scenario.palette.sorted { $0.index < $1.index }.map(makeColor(from:))
        let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, expectedScores.count, scenario.id)
        for (actual, expected) in zip(actualScores, expectedScores) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, scenario.id)
            default:
                XCTFail("\(scenario.id): candidate \(expected.index) score mismatch")
            }
        }

        let selected = selectEarliestLowestScore(from: actualScores)
        XCTAssertEqual(selected, scenario.expected.selectedIndex, scenario.id)

        guard let selected else {
            XCTAssertNil(scenario.expected.error, scenario.id)
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            XCTAssertEqual(scenario.expected.tiedIndices, [], scenario.id)
            return
        }

        guard let expectedHexColor = scenario.expected.selectedHexColor else {
            return XCTFail("\(scenario.id): selected candidate must define an expected hex color")
        }
        XCTAssertEqual(palette[selected].hex, expectedHexColor, scenario.id)
        guard case .score(let error) = actualScores[selected], let expectedError = scenario.expected.error else {
            return XCTFail("\(scenario.id): selected candidate must have a finite expected score")
        }
        XCTAssertEqual(error, expectedError, scenario.id)

        let tiedIndices = actualScores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == error else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        guard let expectedTieBroke = scenario.expected.tieBroke else {
            return XCTFail("\(scenario.id): selected candidate must define tie evidence")
        }
        XCTAssertEqual(tiedIndices.count > 1, expectedTieBroke, scenario.id)
        XCTAssertEqual(tiedIndices.first, selected, scenario.id)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func targetVector(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(responses(from: vector.channels))
    }

    private func makeColor(from vector: ParityVector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw ParityCorpusError.invalidHex(vector.hexColor)
        }
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: rgb,
            responses: responses(from: vector.channels).mapValues {
                IlluminationResponse(brightness: $0)
            }
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func selectEarliestLowestScore(from scores: [ScorerResult]) -> Int? {
        var selection: Int?
        var lowest = Double.infinity
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result, score < lowest else { continue }
            lowest = score
            selection = index
        }
        return selection
    }
}

private enum ParityCorpusError: Error {
    case invalidHex(String)
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String

    private enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case lightSources = "light_sources"
        case missingPolicy = "missing_policy"
        case scenarios, scorer, selection
    }
}

private struct ParityScenario: Decodable {
    let expected: ParityExpectation
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    private enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    private enum CodingKeys: String, CodingKey {
        case channels, index
        case hexColor = "hex_color"
    }
}
