import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorAndSelectionMatchVersionOneCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels.lightingConditions)
        let palette = try scenario.palette.map(makePaletteColor)
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores) {
            XCTAssertEqual(expected.index, scenario.palette.firstIndex { $0.index == expected.index } ?? -1, scenario.id)
            assert(actual, equals: expected.score, scenario: scenario.id)
        }

        let selectable = actualScores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        let selected = selectable.min { $0.1 < $1.1 }
        XCTAssertEqual(selected?.0, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selected.map { palette[$0.0].hex }, scenario.expected.selectedHexColor, scenario.id)
        if let actualError = selected?.1, let expectedError = scenario.expected.error {
            XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertNil(selected, scenario.id)
            XCTAssertNil(scenario.expected.error, scenario.id)
        }

        let tiedIndices = selectable
            .filter { $0.1 == selected?.1 }
            .map(\.0)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id)

        guard scenario.target.containsEveryActiveCondition(in: weights) else { return }
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids(for: scenario.target, weights: weights),
            weights: weights
        )
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
    }

    private func assert(_ actual: ScorerResult, equals expected: CorpusScore, scenario: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("Score disagreed with corpus for \(scenario): \(actual)")
        }
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor))
        let id = try XCTUnwrap(vector.index)
        let responses = vector.channels.lightingConditions.mapValues(IlluminationResponse.init(brightness:))
        return PaletteColor(id: id, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private func sourceGrids(for target: ParityVector, weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [target.channels[$0.rawValue]!]))
        })
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
        let url = file.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    func containsEveryActiveCondition(in weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { channels[$0.rawValue] != nil }
    }
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
            }
            self = .excluded
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

private extension Dictionary where Key == String, Value == Double {
    var lightingConditions: [LightingCondition: Double] {
        reduce(into: [:]) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        }
    }
}
