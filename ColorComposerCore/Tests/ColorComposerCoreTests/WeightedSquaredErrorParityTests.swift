import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedParityCorpusMatchesScorerAndSolverSelections() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels)
        let palette = try scenario.palette.map(makePalette)
        let scores = palette.map { WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(scores, scenario.expected.scores) {
            XCTAssertEqual(expected.index, scenario.palette[expected.index].index, scenario.id)
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .number(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 0, scenario.id)
            default:
                XCTFail("\(scenario.id): score did not match corpus")
            }
        }

        let tiedIndices = tiedIndices(in: scores, at: scenario.expected.error)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        if scenario.expected.error == nil {
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
        } else {
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
        }

        guard scenario.target.containsEvery(weights.activeConditions) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, fill: scenario.target.channels[$0]!))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
    }

    private func tiedIndices(in scores: [ScorerResult], at expectedError: Double?) -> [Int] {
        guard let expectedError else { return [] }
        return scores.enumerated().compactMap { index, score in
            guard case .score(let value) = score, value == expectedError else { return nil }
            return index
        }
    }

    private func makePalette(_ entry: ParityVector) throws -> PaletteColor {
        PaletteColor(
            id: entry.index,
            hex: entry.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: entry.hexColor)),
            responses: entry.channels.mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
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
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int
    let hexColor: String
    let channels: [LightingCondition: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case excluded
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels[LightingCondition.white.rawValue, default: 0],
            red: channels[LightingCondition.red.rawValue, default: 0],
            green: channels[LightingCondition.green.rawValue, default: 0],
            blue: channels[LightingCondition.blue.rawValue, default: 0],
            lps: channels[LightingCondition.lps.rawValue, default: 0]
        )
    }
}

private extension ParityVector {
    func containsEvery(_ conditions: [LightingCondition]) -> Bool {
        conditions.allSatisfy { channels[$0] != nil }
    }
}
