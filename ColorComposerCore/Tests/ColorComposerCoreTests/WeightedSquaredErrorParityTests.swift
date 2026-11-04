import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedV1Corpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makeColor)
            let target = TargetResponseVector(channels(from: scenario.target.channels))
            let weights = makeWeights(scenario.weights)

            for (candidate, expected) in zip(palette, scenario.expected.scores) {
                XCTAssertEqual(candidate.id, expected.index, scenario.id)
                assertScore(
                    scorer.score(candidate: candidate, target: target, weights: weights),
                    equals: expected.score,
                    scenario: scenario.id,
                    candidate: candidate.id
                )
            }

            guard let expectedIndex = scenario.expected.selectedIndex else {
                if hasEveryActiveTargetChannel(scenario.target.channels, weights: weights) {
                    let result = try solve(scenario, palette: palette, weights: weights)
                    XCTAssertNil(result.colorIndex(x: 0, y: 0), scenario.id)
                    XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
                }
                continue
            }

            guard let expectedError = scenario.expected.error else {
                return XCTFail("\(scenario.id) selected a candidate without an expected error")
            }

            let result = try solve(scenario, palette: palette, weights: weights)
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(scenario.expected.tiedIndices.first, expectedIndex, scenario.id)
                for index in scenario.expected.tiedIndices {
                    XCTAssertEqual(scenario.expected.scores[index].score, .value(expectedError), scenario.id)
                }
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makeColor(_ vector: CorpusVector) -> PaletteColor {
        PaletteColor(
            id: vector.index!,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: channels(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
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

    private func channels(from values: [String: Double]) -> [LightingCondition: Double] {
        values.reduce(into: [:]) { channels, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            channels[condition] = entry.value
        }
    }

    private func hasEveryActiveTargetChannel(_ target: [String: Double], weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { target[$0.rawValue] != nil }
    }

    private func solve(
        _ scenario: ParityScenario,
        palette: [PaletteColor],
        weights: ChannelWeights
    ) throws -> CompositionResult {
        let sourceGrids = channels(from: scenario.target.channels).mapValues {
            BrightnessGrid(width: 1, height: 1, values: [$0])
        }
        return try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
    }

    private func assertScore(
        _ actual: ScorerResult,
        equals expected: CorpusScore,
        scenario: String,
        candidate: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario), candidate \(candidate)")
        default:
            XCTFail("\(scenario), candidate \(candidate): expected \(expected), got \(actual)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [CorpusVector]
    let target: CorpusVector
    let weights: [String: Double]
    let expected: ExpectedSelection
}

private struct CorpusVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct ExpectedSelection: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable, Equatable, CustomStringConvertible {
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

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let value): return "\(value)"
        }
    }
}
