import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the versioned golden vectors emitted by `color_matching`.
///
/// The fixture is intentionally decoded from disk instead of duplicated as Swift
/// literals so refreshing it remains a straight upstream-file replacement.
final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = scenario.weights.channelWeights
            let target = TargetResponseVector(scenario.target.channels.lightingValues)
            let palette = scenario.palette.map(makePaletteColor)
            XCTAssertEqual(palette.count, scenario.expected.scores.count, "scenario: \(scenario.id)")

            for (candidate, expected) in zip(palette, scenario.expected.scores) {
                switch (scorer.score(candidate: candidate, target: target, weights: weights), expected.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 0, "scenario: \(scenario.id), color: \(expected.index)")
                default:
                    XCTFail("scenario: \(scenario.id), color: \(expected.index)")
                }
            }
        }
    }

    func testSolverSelectionMatchesVersionOneParityCorpusIncludingTies() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            let activeTarget = scenario.target.channels.lightingValues
            let weights = scenario.weights.channelWeights
            guard weights.activeConditions.allSatisfy({ activeTarget[$0] != nil }) else {
                XCTAssertNil(scenario.expected.selectedIndex, "scenario: \(scenario.id)")
                continue
            }
            let grids = Dictionary(uniqueKeysWithValues: activeTarget.map {
                ($0.key, BrightnessGrid(width: 1, height: 1, values: [$0.value]))
            })
            let result = try CompositionSolver().solve(
                palette: scenario.palette.map(makePaletteColor),
                sourceGrids: grids,
                weights: weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "scenario: \(scenario.id)")
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, "scenario: \(scenario.id)")
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "scenario: \(scenario.id)")
            }

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(
                    scenario.expected.selectedIndex,
                    scenario.expected.tiedIndices.min(),
                    "scenario: \(scenario.id)"
                )
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: vector.channels.lightingValues.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
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
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    enum Score: Equatable {
        case value(Double)
        case excluded
    }

    let index: Int
    let score: Score

    private enum CodingKeys: String, CodingKey {
        case index, score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .value(value)
        } else {
            guard try container.decode(String.self, forKey: .score) == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a score or the excluded sentinel."
                )
            }
            score = .excluded
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    var lightingValues: [LightingCondition: Double] {
        compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }
        .reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: self["white", default: 0],
            red: self["red", default: 0],
            green: self["green", default: 0],
            blue: self["blue", default: 0],
            lps: self["lps", default: 0]
        )
    }
}
