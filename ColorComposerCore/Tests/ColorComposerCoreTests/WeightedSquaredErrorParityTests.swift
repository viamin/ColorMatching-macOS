import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = responseVector(from: scenario.target.channels)
            let weights = channelWeights(from: scenario.weights)
            let palette = scenario.palette.enumerated().map { index, vector in
                makePaletteColor(vector, id: index)
            }

            let actualScores = palette.enumerated().map { index, color in
                let score: Score
                if case .score(let value) = scorer.score(candidate: color, target: target, weights: weights) {
                    score = .value(value)
                } else {
                    score = .excluded
                }
                return ExpectedScore(index: index, score: score)
            }

            XCTAssertEqual(actualScores, scenario.expected.scores, "scenario: \(scenario.id)")

            let selection = selectedIndex(in: palette, target: target, weights: weights, scorer: scorer)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, "scenario: \(scenario.id)")
            XCTAssertEqual(selection.error, scenario.expected.error, "scenario: \(scenario.id)")

            if let index = selection.index {
                XCTAssertEqual(palette[index].hex, scenario.expected.selectedHexColor, "scenario: \(scenario.id)")
            } else {
                XCTAssertNil(scenario.expected.selectedHexColor, "scenario: \(scenario.id)")
            }

            if let error = selection.error {
                XCTAssertEqual(
                    actualScores.filter { $0.score == .value(error) }.map(\.index),
                    scenario.expected.tiedIndices,
                    "scenario: \(scenario.id)"
                )
                XCTAssertEqual(scenario.expected.tieBroke, scenario.expected.tiedIndices.count > 1, "scenario: \(scenario.id)")
            } else {
                XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, "scenario: \(scenario.id)")
                XCTAssertNil(scenario.expected.tieBroke, "scenario: \(scenario.id)")
            }
        }
    }

    private func loadCorpus() throws -> Corpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let data = try Data(contentsOf: fixtureURL)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    private func channelWeights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }

    private func responseVector(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }))
    }

    private func makePaletteColor(_ vector: Vector, id: Int) -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
        })
        return PaletteColor(
            id: id,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses
        )
    }

    private func selectedIndex(
        in palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scorer: WeightedSquaredErrorScorer
    ) -> (index: Int?, error: Double?) {
        var selection: (index: Int?, error: Double?) = (nil, nil)
        for (index, color) in palette.enumerated() {
            guard case .score(let score) = scorer.score(candidate: color, target: target, weights: weights) else {
                continue
            }
            if let bestError = selection.error, score >= bestError {
                continue
            }
            selection = (index, score)
        }
        return selection
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: Vector
    let palette: [Vector]
    let expected: Expected
}

private struct Vector: Decodable {
    let channels: [String: Double]
    let hexColor: String
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable, Equatable {
    let index: Int
    let score: Score
}

private enum Score: Decodable, Equatable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            let value = try container.decode(String.self)
            guard value == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported score: \(value)")
            }
            self = .excluded
        }
    }
}
