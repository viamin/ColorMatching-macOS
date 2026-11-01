import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(
        _ scenario: SolverParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let palette = try scenario.palette.map(makePaletteColor)
        let target = TargetResponseVector(channels(from: scenario.target.channels))
        let weights = makeWeights(scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        for expectation in scenario.expected.scores {
            let actual = scorer.score(
                candidate: palette[expectation.index], target: target, weights: weights
            )
            switch expectation.score {
            case .excluded:
                XCTAssertEqual(actual, .excluded, scenario.id, file: file, line: line)
            case .value(let expected):
                guard case .score(let actualScore) = actual else {
                    return XCTFail("\(scenario.id): candidate \(expectation.index) was excluded", file: file, line: line)
                }
                XCTAssertEqual(actualScore, expected, accuracy: 1e-12, scenario.id, file: file, line: line)
            }
        }

        let active = weights.activeConditions
        if active.allSatisfy({ target.value(for: $0) != nil }) {
            let grids = Dictionary(uniqueKeysWithValues: active.map { condition in
                (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
            })
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id, file: file, line: line)
            XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .infinity, accuracy: 1e-12, scenario.id, file: file, line: line)
            if let selectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
            }
        } else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id, file: file, line: line)
        }

        let tiedIndices = scenario.expected.scores.compactMap { score -> Int? in
            guard case .value(let value) = score.score, value == scenario.expected.error else { return nil }
            return score.index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        if let tieBroke = scenario.expected.tieBroke {
            XCTAssertEqual(tieBroke, tiedIndices.count > 1, scenario.id, file: file, line: line)
        }
    }

    private func makePaletteColor(_ fixture: SolverParityCorpus.PaletteEntry) throws -> PaletteColor {
        PaletteColor(
            id: try XCTUnwrap(fixture.index),
            hex: fixture.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: fixture.hexColor)),
            responses: channels(from: fixture.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func channels(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
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

    private func loadCorpus() throws -> SolverParityCorpus {
        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = sourceDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let selection: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let palette: [PaletteEntry]
        let target: PaletteEntry
        let weights: [String: Double]
        let expected: Expected
    }

    struct PaletteEntry: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [Score]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct Score: Decodable {
        let index: Int
        let score: ScoreValue
    }

    enum ScoreValue: Decodable {
        case value(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else if try container.decode(String.self) == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
            }
        }
    }
}
