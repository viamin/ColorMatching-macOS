import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedServerCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makeColor)
            let target = TargetResponseVector(channelValues(scenario.target.channels))
            let weights = makeWeights(scenario.weights)

            for (candidate, expected) in zip(palette, scenario.expected.scores) {
                switch (scorer.score(candidate: candidate, target: target, weights: weights), expected.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let value)):
                    XCTAssertEqual(actual, value, accuracy: 1e-12, "\(scenario.id), candidate \(expected.index)")
                default:
                    XCTFail("\(scenario.id), candidate \(expected.index): scorer result did not match corpus")
                }
            }

            if hasMeasurementsForEveryActiveChannel(in: scenario) {
                assertSelection(scenario, palette: palette, weights: weights)
            } else {
                XCTAssertNil(scenario.expected.selectedIndex, "\(scenario.id): missing targets exclude every candidate")
            }
        }
    }

    private func assertSelection(_ scenario: Scenario, palette: [PaletteColor], weights: ChannelWeights) {
        let sourceGrids = channelValues(scenario.target.channels).mapValues {
            BrightnessGrid(width: 1, height: 1, values: [$0])
        }

        do {
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)

            if let expectedError = scenario.expected.error,
               let selectedIndex = scenario.expected.selectedIndex,
               let selectedHexColor = scenario.expected.selectedHexColor
            {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
                XCTAssertEqual(palette[selectedIndex].hex, selectedHexColor, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(scenario.expected.selectedIndex, scenario.expected.tiedIndices.min(), "\(scenario.id): ties must select the earliest candidate")
            }
        } catch {
            XCTFail("\(scenario.id): unexpected solver error \(error)")
        }
    }

    private func loadCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func makeColor(_ entry: Vector) -> PaletteColor {
        PaletteColor(
            id: entry.index!,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: channelValues(entry.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
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

    private func channelValues(_ values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func hasMeasurementsForEveryActiveChannel(in scenario: Scenario) -> Bool {
        makeWeights(scenario.weights).activeConditions.allSatisfy {
            channelValues(scenario.target.channels)[$0] != nil
        }
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: Vector
    let palette: [Vector]
    let expected: Expected
}

private struct Vector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: Score
}

private enum Score: Decodable {
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
