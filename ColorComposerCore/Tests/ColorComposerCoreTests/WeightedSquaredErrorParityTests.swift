import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the versioned `color_matching` golden vectors. Keep this test at the
/// solver boundary: it verifies individual score/exclusion results and the
/// earliest-wins selection policy used by `CompositionSolver`.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testVersionOneCorpusMatchesWeightedSquaredErrorAndSelection() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = channelWeights(from: scenario.weights)
        let target = TargetResponseVector(responseVector(from: scenario.target.channels))
        let palette = scenario.palette.map(paletteColor)
        let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id)
        for expected in scenario.expected.scores {
            XCTAssertEqual(scores[expected.index], expected.scorerResult, scenario.id)
        }

        let selectedIndex = scores.enumerated().first { _, result in
            guard case .score = result else { return false }
            let best = scores.compactMap { result -> Double? in
                guard case .score(let score) = result else { return nil }
                return score
            }.min()!
            return result == .score(best)
        }?.offset

        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selectedIndex.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)

        let tiedIndices: [Int]
        if let expectedError = scenario.expected.error {
            tiedIndices = scores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let score) = result, score == expectedError else { return nil }
                return index
            }
        } else {
            tiedIndices = []
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)

        if let expectedIndex = scenario.expected.selectedIndex,
           let expectedError = scenario.expected.error,
           scenario.target.hasMeasurements(for: weights.activeConditions)
        {
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(from: scenario.target.channels, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0], red: values["red", default: 0],
            green: values["green", default: 0], blue: values["blue", default: 0], lps: values["lps", default: 0]
        )
    }

    private func responseVector(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func paletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responseVector(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func sourceGrids(from values: [String: Double], weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [values[condition.rawValue]!]))
        })
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
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

    var scorerResult: ScorerResult {
        switch score {
        case .excluded: return .excluded
        case .score(let value): return .score(value)
        }
    }
}

private enum ParityScore: Decodable {
    case excluded
    case score(Double)

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

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    func hasMeasurements(for conditions: [LightingCondition]) -> Bool {
        conditions.allSatisfy { channels[$0.rawValue] != nil }
    }
}
