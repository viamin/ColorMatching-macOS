import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysVersionOneServerParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = target(from: scenario.target)
            let weights = weights(from: scenario.weights)
            let candidates = scenario.palette.map(candidate(from:))
            let actualScores = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (index, pair) in zip(actualScores, scenario.expected.scores).enumerated() {
                let (actual, expected) = pair
                XCTAssertEqual(expected.index, index, scenario.id)
                switch (actual, expected.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 0, scenario.id)
                default:
                    XCTFail("\(scenario.id): candidate \(expected.index) score mismatch")
                }
            }

            let scored = actualScores.enumerated().compactMap { index, result -> (Int, Double)? in
                guard case .score(let value) = result else { return nil }
                return (index, value)
            }
            let selected = scored.min { left, right in
                left.1 == right.1 ? left.0 < right.0 : left.1 < right.1
            }

            guard let expectedIndex = scenario.expected.selectedIndex else {
                XCTAssertTrue(scored.isEmpty, scenario.id)
                XCTAssertNil(scenario.expected.error, scenario.id)
                XCTAssertNil(scenario.expected.tieBroke, scenario.id)
                XCTAssertEqual(scenario.expected.tiedIndices, [], scenario.id)
                continue
            }

            guard let selected else {
                return XCTFail("\(scenario.id): expected candidate \(expectedIndex) to be selected")
            }
            XCTAssertEqual(selected.0, expectedIndex, scenario.id)
            guard let expectedError = scenario.expected.error else {
                return XCTFail("\(scenario.id): selected candidate is missing an expected error")
            }
            guard let expectedHexColor = scenario.expected.selectedHexColor,
                  let tieBroke = scenario.expected.tieBroke else {
                return XCTFail("\(scenario.id): selected candidate is missing selection metadata")
            }
            XCTAssertEqual(selected.1, expectedError, accuracy: 0, scenario.id)

            let tiedIndices = scored.compactMap { index, score in
                score == selected.1 ? index : nil
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(tiedIndices.count > 1, tieBroke, scenario.id)
            XCTAssertEqual(tiedIndices.first, Optional(expectedIndex), scenario.id)
            XCTAssertEqual(candidates[selected.0].hex, expectedHexColor, scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func weights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
    }

    private func target(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(responses(from: vector.channels))
    }

    private func candidate(from vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index!,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
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
    let expected: ParityExpected
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown score value")
        }
    }
}
