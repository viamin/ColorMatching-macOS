import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedParityCorpusMatchesScoresAndSelections() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertFalse(corpus.scenarios.isEmpty)

        for scenario in corpus.scenarios {
            try assertScorerParity(for: scenario)
            try assertSelectionParity(for: scenario)
            try assertSolverParity(for: scenario)
        }
    }

    private func assertScorerParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = weights(from: scenario.weights)

        for candidate in scenario.palette {
            let index = try XCTUnwrap(candidate.index)
            let actual = scorer.score(
                candidate: paletteColor(from: candidate),
                target: target,
                weights: weights
            )
            let expected = try XCTUnwrap(scenario.expected.scores.first { $0.index == index })

            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case let (.score(actual), .value(expected)):
                XCTAssertEqual(actual, expected, accuracy: 0, "scenario: \(scenario.id), candidate: \(index)")
            default:
                XCTFail("scenario: \(scenario.id), candidate: \(index) disagreed on exclusion")
            }
        }
    }

    private func assertSelectionParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = weights(from: scenario.weights)
        var best: (index: Int, score: Double)?

        for candidate in scenario.palette {
            let index = try XCTUnwrap(candidate.index)
            guard case let .score(score) = scorer.score(
                candidate: paletteColor(from: candidate),
                target: target,
                weights: weights
            ) else { continue }
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }

        XCTAssertEqual(best?.index, scenario.expected.selectedIndex, "scenario: \(scenario.id)")
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(
                try XCTUnwrap(best?.score),
                expectedError,
                accuracy: 0,
                "scenario: \(scenario.id)"
            )
        } else {
            XCTAssertNil(best, "scenario: \(scenario.id)")
        }
        if scenario.expected.tieBroke {
            XCTAssertEqual(best?.index, scenario.expected.tiedIndices.min(), "scenario: \(scenario.id)")
        }
    }

    private func assertSolverParity(for scenario: ParityScenario) throws {
        let weights = weights(from: scenario.weights)
        let activeConditions = weights.activeConditions
        guard activeConditions.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else { return }

        let sourceGrids = Dictionary(uniqueKeysWithValues: activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[condition.rawValue]!]))
        })
        let result = try CompositionSolver().solve(
            palette: scenario.palette.map { paletteColor(from: $0) },
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "scenario: \(scenario.id)")
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, "scenario: \(scenario.id)")
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "scenario: \(scenario.id)")
        }

        if scenario.expected.tieBroke {
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.tiedIndices.min(), "scenario: \(scenario.id)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func paletteColor(from candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index!,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: responses(from: candidate.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
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
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}
