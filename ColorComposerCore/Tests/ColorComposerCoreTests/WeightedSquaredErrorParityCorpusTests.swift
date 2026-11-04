import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testVersionOneCorpusMatchesWeightedSquaredErrorSelection() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(channels: scenario.target.channels)
        let palette = try scenario.palette.map(makePaletteColor)
        let scorer = WeightedSquaredErrorScorer()

        for expected in scenario.expected.scores {
            let actual = scorer.score(candidate: palette[expected.index], target: target, weights: weights)
            switch (expected.score, actual) {
            case (.excluded, .excluded):
                break
            case (.value(let expectedScore), .score(let actualScore)):
                XCTAssertEqual(actualScore, expectedScore, accuracy: 1e-12, scenario.id)
            default:
                XCTFail("\(scenario.id): score at index \(expected.index) differs from corpus")
            }
        }

        guard scenario.target.hasMeasurements(for: weights.activeConditions) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            return
        }

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: grids(for: scenario.target.channels, active: weights.activeConditions),
            weights: weights
        )
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)

        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }

        if scenario.expected.tieBroke == true {
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.tiedIndices?.first, scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ entry: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor), "Invalid corpus hex: \(entry.hexColor)")
        return PaletteColor(
            id: entry.index ?? 0,
            hex: entry.hexColor,
            rgb: rgb,
            responses: entry.channels.reduce(into: [:]) { responses, item in
                guard let condition = LightingCondition(rawValue: item.key) else { return }
                responses[condition] = IlluminationResponse(brightness: item.value)
            }
        )
    }

    private func grids(for channels: [String: Double], active: [LightingCondition]) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: active.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [channels[condition.rawValue]!]))
        })
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
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
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    func hasMeasurements(for conditions: [LightingCondition]) -> Bool {
        conditions.allSatisfy { channels[$0.rawValue] != nil }
    }
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]?
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case value(Double)
    case excluded

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

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(channels.reduce(into: [:]) { brightness, item in
            guard let condition = LightingCondition(rawValue: item.key) else { return }
            brightness[condition] = item.value
        })
    }
}
