import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testVersionOneCorpusMatchesScoresExclusionsAndSelections() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(channels(from: scenario.target.channels))
        let weights = weights(from: scenario.weights)
        let palette = try scenario.palette.map(makeColor)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
            default:
                XCTFail("\(scenario.id): candidate \(expected.index) score did not match corpus")
            }
        }

        let selection = selectedIndex(from: actualScores)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
        assertEqual(selection.error, scenario.expected.error, scenario: scenario.id)
        XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, scenario.id)

        if weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) {
            let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
                (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
            })
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            assertEqual(result.error(x: 0, y: 0), scenario.expected.error, scenario: scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fileURL))
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Corpus contains invalid hex \(vector.hexColor)")
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: rgb,
            responses: channels(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func channels(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func selectedIndex(from scores: [ScorerResult]) -> (index: Int?, error: Double?, tiedIndices: [Int]) {
        let finite = scores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        guard let minimum = finite.map(\.1).min() else { return (nil, nil, []) }
        let tiedIndices = finite.filter { $0.1 == minimum }.map(\.0)
        return (tiedIndices.first, minimum, tiedIndices)
    }

    private func assertEqual(_ actual: Double?, _ expected: Double?, scenario: String) {
        switch (actual, expected) {
        case let (actual?, expected?):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        case (nil, nil):
            break
        default:
            XCTFail("\(scenario): expected \(String(describing: expected)), got \(String(describing: actual))")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]

    private enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scenarios
    }
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

    private enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedIndex: Int?
    let tiedIndices: [Int]

    private enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedIndex = "selected_index"
        case tiedIndices = "tied_indices"
    }
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
        if let score = try? value.decode(Double.self) {
            self = .value(score)
        } else if try value.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected a score or excluded")
        }
    }
}
