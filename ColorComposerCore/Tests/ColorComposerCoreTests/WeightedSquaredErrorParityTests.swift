import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedParityCorpusMatchesScorerSelectionAndScores() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = try scenario.palette.map(makePaletteColor)

            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
            assertScores(actualScores, equal: scenario.expected.scores, scenario: scenario.id)

            let selectedIndex = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case .score = result else { return nil }
                return index
            }.min { left, right in
                guard case let .score(leftScore) = actualScores[left],
                      case let .score(rightScore) = actualScores[right]
                else {
                    return false
                }
                return leftScore < rightScore
            }

            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(
                selectedIndex.map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                scenario.id
            )

            let selectedScore = selectedIndex.flatMap { index -> Double? in
                guard case let .score(score) = actualScores[index] else { return nil }
                return score
            }
            XCTAssertEqual(selectedScore, scenario.expected.error, scenario.id)

            let tiedIndices = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case let .score(score) = result, score == scenario.expected.error else { return nil }
                return index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            if let tieBroke = scenario.expected.tieBroke {
                XCTAssertEqual(tieBroke, tiedIndices.count > 1, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ fixture: PaletteFixture) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: fixture.hexColor), "Invalid fixture color \(fixture.hexColor)")
        return PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: rgb,
            responses: responses(from: fixture.channels)
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func weights(from fixture: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: fixture["white"] ?? 0,
            red: fixture["red"] ?? 0,
            green: fixture["green"] ?? 0,
            blue: fixture["blue"] ?? 0,
            lps: fixture["lps"] ?? 0
        )
    }

    private func assertScores(
        _ actual: [ScorerResult],
        equal expected: [ExpectedScore],
        scenario: String
    ) {
        XCTAssertEqual(actual.count, expected.count, scenario)
        for (index, expectedScore) in expected.enumerated() {
            XCTAssertEqual(expectedScore.index, index, scenario)
            switch (actual[index], expectedScore.score) {
            case (.excluded, .excluded):
                break
            case let (.score(actualScore), .value(expectedValue)):
                XCTAssertEqual(actualScore, expectedValue, scenario)
            default:
                XCTFail("Score mismatch in \(scenario) at candidate \(index)")
            }
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer
        case selection
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [PaletteFixture]
    let target: VectorFixture
    let weights: [String: Double]
    let expected: ExpectedSelection
}

private struct PaletteFixture: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int

    enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct VectorFixture: Decodable {
    let channels: [String: Double]
}

private struct ExpectedSelection: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
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

private struct ExpectedScore: Decodable {
    enum Value: Equatable {
        case value(Double)
        case excluded
    }

    let index: Int
    let score: Value

    enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)

        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .value(value)
        } else {
            guard try container.decode(String.self, forKey: .score) == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a number or the excluded marker."
                )
            }
            score = .excluded
        }
    }
}

