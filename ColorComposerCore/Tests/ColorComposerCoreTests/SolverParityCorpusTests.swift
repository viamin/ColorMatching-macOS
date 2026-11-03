import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesUpstreamV1Corpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makeColor)
            let target = targetVector(from: scenario.target.channels)
            let weights = weights(from: scenario.weights)

            for expectedScore in scenario.expected.scores {
                let candidate = try XCTUnwrap(
                    palette.first { $0.id == expectedScore.index },
                    "Missing candidate \(expectedScore.index) in \(scenario.id)"
                )
                XCTAssertEqual(
                    scorer.score(candidate: candidate, target: target, weights: weights),
                    expectedScore.score.scorerResult,
                    "Score mismatch in \(scenario.id), candidate \(expectedScore.index)"
                )
            }

            try assertSolverSelection(
                for: scenario,
                palette: palette,
                weights: weights
            )
        }
    }

    private func assertSolverSelection(
        for scenario: ParityScenario,
        palette: [PaletteColor],
        weights: ChannelWeights
    ) throws {
        // A missing target measurement cannot be represented by a source grid;
        // its scorer behavior is asserted above. Every other scenario can use
        // the production selection path directly.
        guard scenario.id != "missing-target-excluded" else { return }

        let sourceGrids = Dictionary(uniqueKeysWithValues: scenario.target.channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, BrightnessGrid(width: 1, height: 1, values: [value])) }
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], "Selection mismatch in \(scenario.id)")
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.errors, [expectedError], "Error mismatch in \(scenario.id)")
        } else {
            XCTAssertEqual(result.errors, [.infinity], "Expected no selection in \(scenario.id)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ vector: ParityVector) throws -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: vector.channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func targetVector(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        }))
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
    let selection: String
    let scenarios: [ParityScenario]
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
    let selectedIndex: Int?
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityExpectedScore
}

private enum ParityExpectedScore: Decodable {
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

    var scorerResult: ScorerResult {
        switch self {
        case .excluded: .excluded
        case .value(let value): .score(value)
        }
    }
}
