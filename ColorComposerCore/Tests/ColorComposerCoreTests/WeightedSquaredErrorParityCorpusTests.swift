import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesSharedParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) {
        let scorer = WeightedSquaredErrorScorer()
        let weights = makeWeights(scenario.weights)
        let target = TargetResponseVector(makeResponses(scenario.target.channels))
        let palette = scenario.palette.map(makePaletteColor)
        let expectedScores = Dictionary(uniqueKeysWithValues: scenario.expected.scores.map { ($0.index, $0.score) })

        var selected: (index: Int, color: PaletteColor, error: Double)?
        var actualTiedIndices: [Int] = []

        for (index, color) in palette.enumerated() {
            let actual = scorer.score(candidate: color, target: target, weights: weights)
            assert(actual, matches: expectedScores[index], scenario: scenario.id, candidate: index)

            guard case .score(let error) = actual else { continue }
            if let current = selected {
                if error < current.error {
                    selected = (index, color, error)
                    actualTiedIndices = [index]
                } else if error == current.error {
                    actualTiedIndices.append(index)
                }
            } else {
                selected = (index, color, error)
                actualTiedIndices = [index]
            }
        }

        XCTAssertEqual(selected?.index, scenario.expected.selectedIndex, "Scenario: \(scenario.id)")
        XCTAssertEqual(selected?.color.hex, scenario.expected.selectedHexColor, "Scenario: \(scenario.id)")
        if let expectedError = scenario.expected.error {
            guard let actualError = selected?.error else {
                return XCTFail("Expected a selected score. Scenario: \(scenario.id)")
            }
            XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, "Scenario: \(scenario.id)")
        } else {
            XCTAssertNil(selected, "Scenario: \(scenario.id)")
        }
        XCTAssertEqual(actualTiedIndices, scenario.expected.tiedIndices, "Scenario: \(scenario.id)")
        XCTAssertEqual(actualTiedIndices.count > 1, scenario.expected.tieBroke ?? false, "Scenario: \(scenario.id)")
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WeightedSquaredError/v1/corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: makeResponses(vector.channels)
        )
    }

    private func makeResponses(_ channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ParityScore?,
        scenario: String,
        candidate: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "Scenario: \(scenario), candidate: \(candidate)")
        default:
            XCTFail("Unexpected score. Scenario: \(scenario), candidate: \(candidate)")
        }
    }
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
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityCandidateScore: Decodable {
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded.")
        }
    }
}
