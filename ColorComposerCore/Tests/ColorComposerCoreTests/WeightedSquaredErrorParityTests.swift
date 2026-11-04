import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testVersionOneCorpusMatchesScorerAndSolverSelection() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = makeWeights(scenario.weights)
        let palette = try scenario.palette.map(makeColor)
        let scorer = WeightedSquaredErrorScorer()

        for (candidate, expected) in zip(palette, scenario.expected.scores) {
            XCTAssertEqual(candidate.id, expected.index, scenario.id)
            switch (scorer.score(candidate: candidate, target: target, weights: weights), expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 0, scenario.id)
            default:
                XCTFail("\(scenario.id): candidate \(candidate.id) did not match its corpus score")
            }
        }

        guard let expectedIndex = scenario.expected.selectedIndex,
              let expectedError = scenario.expected.error
        else {
            XCTAssertTrue(scenario.expected.scores.allSatisfy { $0.score == .excluded }, scenario.id)
            return
        }

        let grids = try sourceGrids(from: scenario.target.channels, weights: weights)
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
        XCTAssertEqual(result.palette[expectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, scenario.id)
        XCTAssertEqual(scenario.expected.tiedIndices.first, expectedIndex, scenario.id)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ entry: ParityVector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: entry.hexColor) else {
            throw ParityFixtureError.invalidHex(entry.hexColor)
        }
        return PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: rgb,
            responses: responses(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func sourceGrids(
        from channels: [String: Double],
        weights: ChannelWeights
    ) throws -> [LightingCondition: BrightnessGrid] {
        try Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            guard let value = channels[condition.rawValue] else {
                throw ParityFixtureError.missingTargetChannel(condition)
            }
            return (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        })
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable, Equatable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .value(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
    case missingTargetChannel(LightingCondition)
}
