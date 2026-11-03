import Foundation
import XCTest
@testable import ColorComposerCore

final class ParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesServerParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = scenario.weights.channelWeights
            let target = TargetResponseVector(scenario.target.channels.responses)
            let palette = scenario.palette.map { entry in
                PaletteColor(
                    id: entry.index,
                    hex: entry.hexColor,
                    rgb: RGBColor(hex: entry.hexColor)!,
                    responses: entry.channels.responses.mapValues(IlluminationResponse.init(brightness:))
                )
            }
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (actual, expected) in zip(actualScores, scenario.expected.scores) {
                switch (actual, expected.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
                default:
                    XCTFail("\(scenario.id): score at index \(expected.index) differs")
                }
            }

            let lowest = actualScores.enumerated().compactMap { index, result -> (Int, Double)? in
                guard case .score(let value) = result else { return nil }
                return (index, value)
            }.min { $0.1 < $1.1 }

            XCTAssertEqual(lowest?.0, scenario.expected.selectedIndex, scenario.id)
            if let error = scenario.expected.error {
                guard let actualError = lowest?.1 else {
                    return XCTFail("\(scenario.id): expected a selected candidate")
                }
                XCTAssertEqual(actualError, error, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertNil(lowest, scenario.id)
            }

            let tiedIndices = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let value) = result, value == lowest?.1 else { return nil }
                return index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            if let expectedTieBreak = scenario.expected.tieBroke {
                XCTAssertEqual(tiedIndices.count > 1, expectedTieBreak, scenario.id)
            } else {
                XCTAssertNil(lowest, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Parity/v1/corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case selection
        case missingPolicy = "missing_policy"
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityPaletteEntry]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityPaletteEntry: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]

    enum CodingKeys: String, CodingKey {
        case index
        case hexColor = "hex_color"
        case channels
    }
}

private struct ParityExpected: Decodable {
    let scores: [ParityScore]
    let selectedIndex: Int?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case scores
        case selectedIndex = "selected_index"
        case error
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    var responses: [LightingCondition: Double] {
        reduce(into: [:]) { responses, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                responses[condition] = entry.value
            }
        }
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: self["white"] ?? 0,
            red: self["red"] ?? 0,
            green: self["green"] ?? 0,
            blue: self["blue"] ?? 0,
            lps: self["lps"] ?? 0
        )
    }
}
