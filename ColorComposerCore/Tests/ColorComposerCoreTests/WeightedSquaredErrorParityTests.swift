import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(scenario.target.channels.conditions)
            let weights = ChannelWeights(channels: scenario.weights)
            let palette = scenario.palette.map(PaletteColor.init)
            let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id)
            for (index, pair) in zip(scores.indices, zip(scores, scenario.expected.scores)) {
                let (actual, expected) = pair
                XCTAssertEqual(expected.index, index, scenario.id)
                switch (actual, expected.score) {
                case (.score(let actual), .score(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
                case (.excluded, .excluded):
                    break
                default:
                    XCTFail("\(scenario.id): candidate \(expected.index) had an unexpected eligibility")
                }
            }

            let minimumScore = scores.compactMap(scoreValue).min()
            let selectedIndex = scores.enumerated().first { _, score in
                scoreValue(score) == minimumScore && minimumScore != nil
            }?.offset

            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            let tiedIndices = scores.enumerated().compactMap { index, score in
                scoreValue(score) == minimumScore && minimumScore != nil ? index : nil
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            if let selectedIndex {
                XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor!, scenario.id)
                XCTAssertEqual(scoreValue(scores[selectedIndex]), scenario.expected.error, scenario.id)
            }
        }
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityColor]
    let target: ParityColor
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityColor: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    var conditions: [LightingCondition: Double] {
        reduce(into: [:]) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}

private extension PaletteColor {
    init(_ parityColor: ParityColor) {
        self.init(
            id: parityColor.index ?? -1,
            hex: parityColor.hexColor,
            rgb: RGBColor(hex: parityColor.hexColor)!,
            responses: parityColor.channels.conditions.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}
