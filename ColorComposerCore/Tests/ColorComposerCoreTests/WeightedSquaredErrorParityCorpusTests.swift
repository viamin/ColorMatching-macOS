import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCommittedParityCorpusMatchesScorerAndSelectionExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true }, "Corpus must contain a tie case")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil }, "Corpus must contain an all-excluded case")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let weights = makeWeights(scenario.weights)
        let target = try makeTarget(scenario.target)
        let palette = try scenario.palette.map(makeColor)
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, scenario.id)
            default:
                XCTFail("\(scenario.id): candidate \(expected.index) score differs from corpus")
            }
        }

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: try sourceGrids(for: scenario.target, weights: weights),
            weights: weights
        )
        assertSelection(result, matches: scenario)
        assertTieEvidence(actualScores, matches: scenario)
    }

    private func assertSelection(_ result: CompositionResult, matches scenario: ParityScenario) {
        guard let expectedIndex = scenario.expected.selectedIndex else {
            XCTAssertNil(result.colorIndex(x: 0, y: 0), scenario.id)
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            return
        }
        guard let expectedError = scenario.expected.error else {
            return XCTFail("\(scenario.id): selected scenario has no expected error")
        }
        guard let expectedHexColor = scenario.expected.selectedHexColor else {
            return XCTFail("\(scenario.id): selected scenario has no expected color")
        }

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
        XCTAssertEqual(scenario.palette[expectedIndex].hexColor, expectedHexColor, scenario.id)
    }

    private func assertTieEvidence(_ scores: [ScorerResult], matches scenario: ParityScenario) {
        guard let expectedError = scenario.expected.error else {
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            XCTAssertEqual(scenario.expected.tiedIndices, [], scenario.id)
            return
        }

        let tiedIndices = scores.enumerated().compactMap { index, score -> Int? in
            guard case .score(let value) = score, value == expectedError else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, Optional(tiedIndices.count > 1), scenario.id)
        XCTAssertEqual(tiedIndices.first, scenario.expected.selectedIndex, scenario.id)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func makeTarget(_ vector: ParityVector) throws -> TargetResponseVector {
        TargetResponseVector(try makeResponses(vector.channels))
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus hex color \(vector.hexColor)")
        return PaletteColor(
            id: try XCTUnwrap(vector.index, "Palette vectors require indices"),
            hex: vector.hexColor,
            rgb: rgb,
            responses: try makeResponses(vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func makeResponses(_ channels: [String: Double]) throws -> [LightingCondition: Double] {
        try Dictionary(uniqueKeysWithValues: channels.map { key, value in
            let condition = try XCTUnwrap(LightingCondition(rawValue: key), "Unknown corpus light source \(key)")
            return (condition, value)
        })
    }

    private func sourceGrids(
        for target: ParityVector,
        weights: ChannelWeights
    ) throws -> [LightingCondition: BrightnessGrid] {
        try Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            let value = try XCTUnwrap(target.channels[condition.rawValue], "Missing target \(condition.rawValue)")
            return (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        })
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
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
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable {
    case excluded
    case value(Double)

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
