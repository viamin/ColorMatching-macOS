import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testVersionOneCorpusMatchesScoresSelectionsAndTies() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScenarioMatchesCorpus(scenario)
        }
    }

    private func assertScenarioMatchesCorpus(
        _ scenario: WeightedSquaredErrorParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let weights = makeWeights(from: scenario.weights)
        let target = TargetResponseVector(makeResponses(from: scenario.target.channels))
        let palette = try scenario.palette.map(makePaletteColor)
        let scorer = WeightedSquaredErrorScorer()

        for expectedScore in scenario.expected.scores {
            let actual = scorer.score(
                candidate: palette[expectedScore.index],
                target: target,
                weights: weights
            )
            assertScore(actual, matches: expectedScore.score, scenarioID: scenario.id, file: file, line: line)
        }

        let actualTies = tiedIndices(
            palette: palette,
            target: target,
            weights: weights,
            expectedError: scenario.expected.error
        )
        XCTAssertEqual(actualTies, scenario.expected.tiedIndices, "scenario \(scenario.id)", file: file, line: line)
        XCTAssertEqual(
            actualTies.count > 1,
            scenario.expected.tieBroke,
            "scenario \(scenario.id)",
            file: file,
            line: line
        )

        guard targetHasEveryActiveMeasurement(target, weights: weights) else {
            XCTAssertNil(scenario.expected.selectedIndex, "scenario \(scenario.id)", file: file, line: line)
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: target.brightness[condition]!))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], "scenario \(scenario.id)", file: file, line: line)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.errors, [expectedError], "scenario \(scenario.id)", file: file, line: line)
        }
    }

    private func assertScore(
        _ actual: ScorerResult,
        matches expected: WeightedSquaredErrorParityCorpus.Score,
        scenarioID: String,
        file: StaticString,
        line: UInt
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, "scenario \(scenarioID)", file: file, line: line)
        default:
            XCTFail("scenario \(scenarioID): score disagrees with corpus", file: file, line: line)
        }
    }

    private func tiedIndices(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        expectedError: Double?
    ) -> [Int] {
        guard let expectedError else { return [] }
        let scorer = WeightedSquaredErrorScorer()
        return palette.indices.filter {
            scorer.score(candidate: palette[$0], target: target, weights: weights) == .score(expectedError)
        }
    }

    private func targetHasEveryActiveMeasurement(_ target: TargetResponseVector, weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { target.brightness[$0] != nil }
    }

    private func makeWeights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }

    private func makePaletteColor(_ vector: WeightedSquaredErrorParityCorpus.Vector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor))
        return PaletteColor(
            id: try XCTUnwrap(vector.index),
            hex: vector.hexColor,
            rgb: rgb,
            responses: makeResponses(from: vector.channels)
        )
    }

    private func makeResponses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func loadCorpus() throws -> WeightedSquaredErrorParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(WeightedSquaredErrorParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct WeightedSquaredErrorParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let palette: [Vector]
        let target: Vector
        let weights: [String: Double]
        let expected: Expected
    }

    struct Vector: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int?
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [ExpectedScore]
        let selectedIndex: Int?
        let tieBroke: Bool
        let tiedIndices: [Int]
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: Score
    }

    enum Score: Decodable {
        case excluded
        case value(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else {
                guard try container.decode(String.self) == "excluded" else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Expected a numeric score or excluded"
                    )
                }
                self = .excluded
            }
        }
    }
}
