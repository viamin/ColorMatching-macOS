import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesScoresAndSelections() throws {
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
        let weights = makeWeights(from: scenario.weights)
        let target = TargetResponseVector(makeChannels(from: scenario.target.channels))
        let palette = try scenario.palette.map(makeColor)

        XCTAssertEqual(scenario.palette.map { $0.index }, Array(scenario.palette.indices), scenario.id)
        XCTAssertEqual(scenario.expected.scores.map(\.index), Array(scenario.palette.indices), scenario.id)

        for expectedScore in scenario.expected.scores {
            let actual = scorer.score(
                candidate: palette[expectedScore.index],
                target: target,
                weights: weights
            )
            assert(actual, equals: expectedScore.score, scenarioID: scenario.id, index: expectedScore.index)
        }

        let activeConditions = weights.activeEntries.map(\.condition)
        guard activeConditions.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            XCTAssertNil(scenario.expected.error, scenario.id)
            return
        }

        let grids = Dictionary(uniqueKeysWithValues: activeConditions.map { condition in
            (condition, BrightnessGrid(
                width: 1,
                height: 1,
                fill: scenario.target.channels[condition.rawValue]!
            ))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: grids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.errors[0], expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertEqual(result.errors[0], .infinity, scenario.id)
        }
    }

    private func assert(
        _ actual: ScorerResult,
        equals expected: ParityScore,
        scenarioID: String,
        index: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\\(scenarioID), candidate \\(index)")
        default:
            XCTFail("\\(scenarioID), candidate \\(index): expected \\(expected), got \\(actual)")
        }
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus color \\(vector.hexColor)")
        let responses = Dictionary(uniqueKeysWithValues: makeChannels(from: vector.channels).map { condition, brightness in
            (condition, IlluminationResponse(brightness: brightness))
        })
        return PaletteColor(
            id: try XCTUnwrap(vector.index, "Corpus palette color has no index"),
            hex: vector.hexColor,
            rgb: rgb,
            responses: responses
        )
    }

    private func makeChannels(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
    }

    private func makeWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: file))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpectation
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedIndex: Int?
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return String(value)
        }
    }
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}
