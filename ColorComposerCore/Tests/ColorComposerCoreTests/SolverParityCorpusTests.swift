import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testV1CorpusReplaysScorerSelectionsScoresAndTiesExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScorerParity(for: scenario)
            try assertSolverSelectionParity(for: scenario)
        }
    }

    private func assertScorerParity(for scenario: Scenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let palette = try palette(from: scenario)
        let target = target(from: scenario.target)
        let weights = weights(from: scenario.weights)
        let actual = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actual.count, scenario.expected.scores.count, scenario.id)
        for (result, expected) in zip(actual, scenario.expected.scores.sorted { $0.index < $1.index }) {
            switch (result, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actualScore), .value(let expectedScore)):
                XCTAssertEqual(actualScore, expectedScore, scenario.id)
            default:
                XCTFail("\(scenario.id): score mismatch at palette index \(expected.index)")
            }
        }

        let expectedTies = scenario.expected.scores.compactMap { score -> Int? in
            guard case .value(let value) = score.score, value == scenario.expected.error else { return nil }
            return score.index
        }
        XCTAssertEqual(expectedTies, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, expectedTies.count > 1, scenario.id)
    }

    private func assertSolverSelectionParity(for scenario: Scenario) throws {
        guard let selectedIndex = scenario.expected.selectedIndex,
              let expectedError = scenario.expected.error
        else { return }

        let target = target(from: scenario.target)
        let weights = weights(from: scenario.weights)
        let grids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
        })
        let result = try CompositionSolver().solve(
            palette: try palette(from: scenario), sourceGrids: grids, weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func palette(from scenario: Scenario) throws -> [PaletteColor] {
        try scenario.palette.sorted { $0.index < $1.index }.map { candidate in
            PaletteColor(
                id: candidate.index,
                hex: candidate.hexColor,
                rgb: try XCTUnwrap(RGBColor(hex: candidate.hexColor)),
                responses: responses(from: candidate.channels)
            )
        }
    }

    private func target(from vector: Vector) -> TargetResponseVector {
        TargetResponseVector(vector.channels.compactMapKeys(LightingCondition.init(rawValue:)))
    }

    private func weights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white", default: 0], red: encoded["red", default: 0],
            green: encoded["green", default: 0], blue: encoded["blue", default: 0],
            lps: encoded["lps", default: 0]
        )
    }

    private func responses(from encoded: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        encoded.compactMapKeys(LightingCondition.init(rawValue:)).mapValues(IlluminationResponse.init(brightness:))
    }
}

private extension Dictionary where Key == String, Value == Double {
    func compactMapKeys<T>(_ transform: (String) -> T?) -> [T: Double] where T: Hashable {
        reduce(into: [:]) { result, entry in
            if let key = transform(entry.key) { result[key] = entry.value }
        }
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [Vector]
    let target: Vector
    let weights: [String: Double]
    let expected: Expected
}

private struct Vector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(Double.self) {
            self = .value(value)
        } else if try decoder.singleValueContainer().decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(), debugDescription: "Expected a score or excluded"
            )
        }
    }
}
