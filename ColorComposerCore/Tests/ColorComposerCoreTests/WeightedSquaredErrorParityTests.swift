import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesSelectionsAndScores() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let palette = scenario.palette.map(makePaletteColor)
        let target = makeTarget(scenario.target)
        let weights = makeWeights(scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        for (candidate, expected) in zip(palette, scenario.expected.scores) {
            XCTAssertEqual(candidate.id, expected.index, scenario.id)
            switch (scorer.score(candidate: candidate, target: target, weights: weights), expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let value)):
                XCTAssertEqual(actual, value, accuracy: 1e-12, scenario.id)
            default:
                XCTFail("\(scenario.id): candidate \(candidate.id) score disagreed with corpus")
            }
        }

        guard LightingCondition.all.allSatisfy({
            scenario.weights[$0.rawValue, default: 0] <= 0 || scenario.target.channels[$0.rawValue] != nil
        }) else {
            return XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
        }

        let sourceGrids = try sourceGrids(for: scenario, weights: weights)
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)

        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
    }

    private func sourceGrids(for scenario: ParityScenario, weights: ChannelMap) throws -> [LightingCondition: BrightnessGrid] {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in LightingCondition.all where weights[condition.rawValue, default: 0] > 0 {
            guard let value = scenario.target.channels[condition.rawValue] else {
                return [:]
            }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return grids
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        let responses = vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { responses, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            responses[condition] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: vector.index ?? -1, hex: vector.hexColor, rgb: RGBColor(hex: vector.hexColor)!, responses: responses)
    }

    private func makeTarget(_ vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(vector.channels.reduce(into: [LightingCondition: Double]()) { values, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            values[condition] = entry.value
        })
    }

    private func makeWeights(_ values: ChannelMap) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0], red: values["red", default: 0],
            green: values["green", default: 0], blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: file))
    }
}

private typealias ChannelMap = [String: Double]

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: ChannelMap
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: ChannelMap
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let selectedIndex: Int?
    let scores: [ParityCandidateScore]
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Double.self) {
            self = .value(number)
        } else {
            guard try value.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected a numeric score or excluded")
            }
            self = .excluded
        }
    }
}
