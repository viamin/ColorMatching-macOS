import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the backend's committed golden vectors. Keep the fixture byte-for-byte
/// in sync with `viamin/color_matching`'s `priv/parity/v1/corpus.json`.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorAndSelectionMatchParityCorpus() throws {
        let corpus = try decodeCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertFalse(corpus.scenarios.isEmpty)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = try scenario.palette.sorted { $0.index < $1.index }.map(makeColor)
            let target = makeTarget(scenario.target)
            let weights = makeWeights(scenario.weights)
            let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }

            XCTAssertEqual(palette.count, expectedScores.count, scenario.id)
            let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
            for (result, expected) in zip(results, expectedScores) {
                assert(result, matches: expected.score, scenarioID: scenario.id, candidateIndex: expected.index)
            }

            let selection = earliestSelection(in: results)
            assert(selection, matches: scenario.expected, palette: palette, scenarioID: scenario.id)

            if weights.activeEntries.allSatisfy({ target.value(for: $0.condition) != nil }) {
                let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeEntries.map { condition, _ in
                    (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
                })
                let composition = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: sourceGrids,
                    weights: weights
                )
                XCTAssertEqual(composition.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
                XCTAssertEqual(composition.error(x: 0, y: 0), scenario.expected.error, scenario.id)
            }
        }
    }

    private func decodeCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity-v1-corpus.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func makeColor(_ vector: Vector) throws -> PaletteColor {
        let responses = try vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) {
            responses, channel in
            guard let condition = LightingCondition(rawValue: channel.key) else { return }
            responses[condition] = IlluminationResponse(brightness: channel.value)
        }
        return PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func makeTarget(_ vector: Vector) -> TargetResponseVector {
        TargetResponseVector(vector.channels.reduce(into: [LightingCondition: Double]()) { values, channel in
            guard let condition = LightingCondition(rawValue: channel.key) else { return }
            values[condition] = channel.value
        })
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func assert(_ result: ScorerResult, matches score: Score, scenarioID: String, candidateIndex: Int) {
        switch (result, score) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, "\(scenarioID), candidate \(candidateIndex)")
        default:
            XCTFail("\(scenarioID), candidate \(candidateIndex): \(result) did not match \(score)")
        }
    }

    private func earliestSelection(in results: [ScorerResult]) -> (Int, Double)? {
        var selection: (Int, Double)?
        for (index, result) in results.enumerated() {
            guard case .score(let score) = result else { continue }
            if selection == nil || score < selection!.1 {
                selection = (index, score)
            }
        }
        return selection
    }

    private func assert(
        _ selection: (Int, Double)?,
        matches expected: Expected,
        palette: [PaletteColor],
        scenarioID: String
    ) {
        guard let expectedIndex = expected.selectedIndex else {
            XCTAssertNil(selection, scenarioID)
            XCTAssertNil(expected.tieBroke, scenarioID)
            XCTAssertEqual(expected.tiedIndices, [], scenarioID)
            return
        }
        XCTAssertEqual(selection?.0, expectedIndex, scenarioID)
        XCTAssertEqual(selection?.1, expected.error, scenarioID)
        XCTAssertEqual(palette[expectedIndex].hex, expected.selectedHexColor, scenarioID)

        let tiedIndices = expected.scores.compactMap { score -> Int? in
            guard case .value(let value) = score.score, value == expected.error else { return nil }
            return score.index
        }
        XCTAssertEqual(expected.tiedIndices, tiedIndices, scenarioID)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, scenarioID)
        XCTAssertEqual(tiedIndices.first, expectedIndex, scenarioID)
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
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
    let channels: [String: Double]
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
    let score: Score
}

private enum Score: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}
