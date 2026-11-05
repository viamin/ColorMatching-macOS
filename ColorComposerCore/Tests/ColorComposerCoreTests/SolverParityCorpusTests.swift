import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesServerParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertFalse(corpus.scenarios.isEmpty)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = makeTarget(scenario.target.channels)
            let palette = scenario.palette.map(makePaletteColor)

            for (candidate, expected) in zip(palette, scenario.expected.scores) {
                XCTAssertEqual(candidate.id, expected.index, scenario.id)
                switch (scorer.score(candidate: candidate, target: target, weights: weights), expected.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let expected)):
                    XCTAssertEqual(actual, expected, scenario.id)
                default:
                    XCTFail("Unexpected candidate score in \\(scenario.id), index \\(candidate.id)")
                }
            }

            guard hasTargetValuesForEveryActiveCondition(scenario.target.channels, weights: weights) else {
                XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
                continue
            }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: makeSourceGrids(scenario.target.channels, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(
                result.error(x: 0, y: 0),
                try XCTUnwrap(scenario.expected.error),
                scenario.id
            )

            if scenario.expected.tieBroke == true {
                XCTAssertEqual(scenario.expected.selectedIndex, scenario.expected.tiedIndices.first, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
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

    private func makeTarget(_ channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(knownChannels(channels))
    }

    private func makePaletteColor(_ fixture: ParityPaletteColor) -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: knownChannels(fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func makeSourceGrids(
        _ channels: [String: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: channels[condition.rawValue]!))
        })
    }

    private func hasTargetValuesForEveryActiveCondition(
        _ channels: [String: Double],
        weights: ChannelWeights
    ) -> Bool {
        weights.activeConditions.allSatisfy { channels[$0.rawValue] != nil }
    }

    private func knownChannels(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityPaletteColor]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityPaletteColor: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case value(Double)
    case excluded

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
