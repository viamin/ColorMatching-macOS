import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = ChannelWeights(scenario.weights)
            let target = TargetResponseVector(scenario.target.channels.conditions)
            let palette = try scenario.palette.map(PaletteColor.init)

            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
            assertScores(actualScores, match: scenario.expected.scores, scenario: scenario.id)

            guard let expectedIndex = scenario.expected.selectedIndex,
                  let expectedError = scenario.expected.error,
                  let expectedHexColor = scenario.expected.selectedHexColor,
                  let expectedTieBroke = scenario.expected.tieBroke
            else {
                XCTAssertTrue(actualScores.allSatisfy { $0 == .excluded }, scenario.id)
                continue
            }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(for: target, weights: weights),
                weights: weights
            )
            let selected = result.colorIndex(x: 0, y: 0)
            XCTAssertEqual(selected, expectedIndex, scenario.id)
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
            XCTAssertEqual(palette[selected!].hex, expectedHexColor, scenario.id)

            let tied = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let score) = result, score == expectedError else { return nil }
                return index
            }
            XCTAssertEqual(tied, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(tied.count > 1, expectedTieBroke, scenario.id)
        }
    }

    private func assertScores(_ actual: [ScorerResult], match expected: [ExpectedScore], scenario: String) {
        XCTAssertEqual(actual.count, expected.count, scenario)
        for expectation in expected {
            switch (actual[expectation.index], expectation.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actualScore), .value(let expectedScore)):
                XCTAssertEqual(actualScore, expectedScore, accuracy: 1e-12, scenario)
            default:
                XCTFail("Unexpected score at index \(expectation.index) in \(scenario)")
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func sourceGrids(for target: TargetResponseVector, weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: target.value(for: condition)!))
        })
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [CorpusColor]
    let target: CorpusColor
    let weights: CorpusChannels
    let expected: CorpusExpectation
}

private struct CorpusColor: Decodable {
    let index: Int?
    let hexColor: String
    let channels: CorpusChannels
}

private struct CorpusChannels: Decodable {
    let white: Double?
    let red: Double?
    let green: Double?
    let blue: Double?
    let lps: Double?

    var conditions: [LightingCondition: Double] {
        [
            .white: white,
            .red: red,
            .green: green,
            .blue: blue,
            .lps: lps
        ].compactMapValues { $0 }
    }
}

private struct CorpusExpectation: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable {
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

private extension ChannelWeights {
    init(_ channels: CorpusChannels) {
        self.init(
            white: channels.white ?? 0,
            red: channels.red ?? 0,
            green: channels.green ?? 0,
            blue: channels.blue ?? 0,
            lps: channels.lps ?? 0
        )
    }
}

private extension PaletteColor {
    init(_ color: CorpusColor) throws {
        guard let rgb = RGBColor(hex: color.hexColor) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid hex color"))
        }
        self.init(
            id: color.index ?? -1,
            hex: color.hexColor,
            rgb: rgb,
            responses: color.channels.conditions.mapValues(IlluminationResponse.init(brightness:))
        )
    }
}
