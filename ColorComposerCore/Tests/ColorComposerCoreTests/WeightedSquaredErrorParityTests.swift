import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1ParityCorpusMatchesScoresAndSelections() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.scenarios.filter(\.expected.tieBroke).count, 4)

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: Scenario) throws {
        let palette = scenario.palette.map(makeColor)
        let target = TargetResponseVector(scenario.target.channels)
        let scores = palette.map { WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: scenario.weights) }

        XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), scenario.id)
        XCTAssertEqual(scores, scenario.expected.scores.map(expectedScore), scenario.id)

        let eligibleIndices = scores.enumerated().compactMap { index, score -> Int? in
            guard case .score = score else { return nil }
            return index
        }
        XCTAssertEqual(eligibleIndices.isEmpty, scenario.expected.selectedIndex == nil, scenario.id)

        guard let expectedIndex = scenario.expected.selectedIndex else {
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, scenario.id)
            return
        }
        let tiedIndices = scores.enumerated().compactMap { index, score -> Int? in
            score == .score(scenario.expected.error!) ? index : nil
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
        let result = try solve(for: scenario, palette: palette)
        XCTAssertEqual(result.colorIndices[0], expectedIndex, scenario.id)
        XCTAssertEqual(result.errors[0], scenario.expected.error, scenario.id)
        XCTAssertEqual(palette[expectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
    }

    private func solve(for scenario: Scenario, palette: [PaletteColor]) throws -> CompositionResult {
        let grids = Dictionary(uniqueKeysWithValues: scenario.weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: scenario.target.channels[condition]!))
        })
        return try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: scenario.weights)
    }

    private func makeColor(_ vector: Vector) -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: vector.channels.map { condition, brightness in
            (condition, IlluminationResponse(brightness: brightness))
        })
        return PaletteColor(id: vector.index ?? -1, hex: vector.hexColor, rgb: RGBColor(hex: vector.hexColor)!, responses: responses)
    }

    private func expectedScore(_ score: ExpectedScore) -> ScorerResult {
        score.value.map(ScorerResult.score) ?? .excluded
    }

    private func loadCorpus() throws -> Corpus {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fileURL))
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: ChannelWeights
    let target: Vector
    let palette: [Vector]
    let expected: Expected
}

private struct Vector: Decodable {
    let channels: [LightingCondition: Double]
    let hexColor: String
    let index: Int?
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
    let value: Double?

    private enum CodingKeys: String, CodingKey {
        case index
        case value = "score"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        value = try? container.decode(Double.self, forKey: .value)
    }
}
