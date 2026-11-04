import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = try scenario.palette.map(makePaletteColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            for (expected, actual) in zip(scenario.expected.scores, actualScores) {
                XCTAssertEqual(expected.index, scenario.palette[expected.index].index, scenario.id)
                switch (expected.score, actual) {
                case (.excluded, .excluded):
                    break
                case (.value(let expectedScore), .score(let actualScore)):
                    XCTAssertEqual(actualScore, expectedScore, scenario.id)
                default:
                    XCTFail("\(scenario.id): candidate \(expected.index) score differs from corpus")
                }
            }

            let selected = actualScores.enumerated().first { _, score in
                if case .score(let value) = score {
                    return value == actualScores.compactMap(scoreValue).min()
                }
                return false
            }?.offset

            XCTAssertEqual(selected, scenario.expected.selectedIndex, scenario.id)
            if let selected {
                XCTAssertEqual(palette[selected].hex, scenario.expected.selectedHexColor, scenario.id)
                XCTAssertEqual(scoreValue(actualScores[selected]), scenario.expected.error, scenario.id)
            } else {
                XCTAssertNil(scenario.expected.error, scenario.id)
            }
            XCTAssertEqual(tiedIndices(in: actualScores), scenario.expected.tiedIndices, scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let data = try Data(contentsOf: testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json"))
        return try JSONDecoder().decode(ParityCorpus.self, from: data)
    }

    private func makePaletteColor(_ entry: CorpusVector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: entry.hexColor) else { throw CorpusError.invalidHex(entry.hexColor) }
        return PaletteColor(
            id: entry.index ?? 0,
            hex: entry.hexColor,
            rgb: rgb,
            responses: responses(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
            channels[condition.rawValue].map { (condition, $0) }
        })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
    }

    private func tiedIndices(in scores: [ScorerResult]) -> [Int] {
        guard let minimum = scores.compactMap(scoreValue).min() else { return [] }
        return scores.enumerated().compactMap { index, score in
            scoreValue(score) == minimum ? index : nil
        }
    }
}

private enum CorpusError: Error {
    case invalidHex(String)
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: CorpusVector
    let palette: [CorpusVector]
    let expected: ExpectedResult
}

private struct CorpusVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ExpectedResult: Decodable {
    let scores: [ExpectedScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown corpus score")
        }
    }
}
