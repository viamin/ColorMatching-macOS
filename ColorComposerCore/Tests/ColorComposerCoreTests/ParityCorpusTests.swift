import Foundation
import XCTest
@testable import ColorComposerCore

final class ParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = channelWeights(from: scenario.weights)
            let palette = try scenario.palette.map(makePaletteColor)
            let actualScores = palette.map {
                WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights)
            }

            XCTAssertEqual(
                actualScores,
                scenario.expected.scores.map(scorerResult),
                "scenario: \(scenario.id)"
            )
            XCTAssertEqual(
                scenario.expected.scores.map(\.index),
                Array(palette.indices),
                "scenario: \(scenario.id)"
            )

            let tiedIndices = indices(scoring: scenario.expected.error, in: actualScores)
            let selectedIndex = tiedIndices.first
            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, "scenario: \(scenario.id)")

            if let selectedIndex {
                XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, "scenario: \(scenario.id)")
            }
            XCTAssertEqual(
                tiedIndices,
                scenario.expected.tiedIndices,
                "scenario: \(scenario.id)"
            )
            XCTAssertEqual(scenario.expected.tieBroke, scenario.expected.tiedIndices.count > 1, "scenario: \(scenario.id)")

            if let sourceGrids = sourceGrids(for: scenario, weights: weights) {
                let result = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: sourceGrids,
                    weights: weights
                )
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "scenario: \(scenario.id)")
                if let expectedError = scenario.expected.error {
                    XCTAssertEqual(result.error(x: 0, y: 0), expectedError, "scenario: \(scenario.id)")
                } else {
                    XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "scenario: \(scenario.id)")
                }
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: vector.hexColor) else { throw ParityTestError.invalidHex(vector.hexColor) }
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: rgb,
            responses: responses(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
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

    private func sourceGrids(
        for scenario: ParityScenario,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid]? {
        let channels = responses(from: scenario.target.channels)
        guard weights.activeConditions.allSatisfy({ channels[$0] != nil }) else { return nil }
        return Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [channels[condition]!]))
        })
    }

    private func scorerResult(_ expected: ParityScore) -> ScorerResult {
        switch expected.score {
        case .excluded: return .excluded
        case .score(let value): return .score(value)
        }
    }

    private func indices(scoring expectedError: Double?, in results: [ScorerResult]) -> [Int] {
        guard let expectedError else { return [] }
        return results.enumerated().compactMap { index, result in
            guard case .score(let score) = result, score == expectedError else { return nil }
            return index
        }
    }
}

private enum ParityTestError: Error {
    case invalidHex(String)
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case missingPolicy = "missing_policy"
        case scenarios
    }
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

    enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
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
