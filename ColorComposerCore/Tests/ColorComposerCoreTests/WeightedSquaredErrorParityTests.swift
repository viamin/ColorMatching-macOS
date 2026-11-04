import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testVersionOneCorpusMatchesScorerAndSolverSelections() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScorerParity(for: scenario)
            try assertSolverParityWhenTargetIsComplete(for: scenario)
        }
    }

    private func assertScorerParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let palette = try scenario.palette.map(makePaletteColor)
        let target = makeTarget(scenario.target)
        let weights = makeWeights(scenario.weights)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for expectedScore in scenario.expected.scores {
            let actual = actualScores[expectedScore.index]
            switch (actual, expectedScore.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
            default:
                XCTFail("\\(scenario.id): score at index \\(expectedScore.index) differed from the corpus")
            }
        }

        let selection = selectedIndex(from: actualScores)
        XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(selection.tiedIndices.count > 1, scenario.expected.tieBroke, scenario.id)

        if let selectedIndex = selection.index {
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(try XCTUnwrap(selection.error), try XCTUnwrap(scenario.expected.error), accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertNil(scenario.expected.error, scenario.id)
            XCTAssertNil(scenario.expected.selectedHexColor, scenario.id)
        }
    }

    private func assertSolverParityWhenTargetIsComplete(for scenario: ParityScenario) throws {
        let weights = makeWeights(scenario.weights)
        let active = weights.activeConditions
        guard active.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else { return }

        let sourceGrids = Dictionary(uniqueKeysWithValues: active.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: scenario.target.channels[condition.rawValue]!))
        })
        let result = try CompositionSolver().solve(
            palette: try scenario.palette.map(makePaletteColor),
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.errors.count, 1, scenario.id)
            XCTAssertEqual(result.errors[0], expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertEqual(result.errors, [.infinity], scenario.id)
        }
    }

    private func selectedIndex(from scores: [ScorerResult]) -> (index: Int?, error: Double?, tiedIndices: [Int]) {
        let eligible = scores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        guard let minimum = eligible.map(\\.1).min() else { return (nil, nil, []) }
        let tiedIndices = eligible.filter { $0.1 == minimum }.map(\\.0)
        return (tiedIndices.first, minimum, tiedIndices)
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: vector.channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
        return PaletteColor(
            id: try XCTUnwrap(vector.index),
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func makeTarget(_ vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: vector.channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        }))
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

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
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
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
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
}
