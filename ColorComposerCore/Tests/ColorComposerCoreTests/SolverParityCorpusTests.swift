import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedColorMatchingCorpus() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let corpus = try decoder.decode(ParityCorpus.self, from: try fixtureData())
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makeColor)
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = makeWeights(scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(scenario.expected.scores.count, actualScores.count, scenario.id)
            for (expected, actual) in zip(scenario.expected.scores, actualScores) {
                switch (expected.score, actual) {
                case (.number(let expectedScore), .score(let actualScore)):
                    XCTAssertEqual(actualScore, expectedScore, scenario.id)
                case (.excluded, .excluded):
                    break
                default:
                    XCTFail("\\(scenario.id): candidate \\(expected.index) score mismatch")
                }
            }

            let selection = firstBestIndex(in: actualScores)
            XCTAssertEqual(selection, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selection.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)

            if let selectedIndex = selection, let expectedError = scenario.expected.error {
                guard case .score(let error) = actualScores[selectedIndex] else {
                    return XCTFail("\\(scenario.id): selected candidate was excluded")
                }
                XCTAssertEqual(error, expectedError, scenario.id)
            }

            if scenario.targetHasEveryActiveCondition(for: weights) {
                let result = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: sourceGrids(for: scenario.target.channels, weights: weights),
                    weights: weights
                )
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
                if let expectedError = scenario.expected.error {
                    XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
                } else {
                    XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
                }
            }
        }
    }

    private func fixtureData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/color-matching-solver-parity-v1.json")
        return try Data(contentsOf: url)
    }

    private func makeColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index!,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0], red: weights["red", default: 0],
            green: weights["green", default: 0], blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func firstBestIndex(in scores: [ScorerResult]) -> Int? {
        scores.enumerated().reduce(into: (index: nil as Int?, score: Double.infinity)) { best, candidate in
            guard case .score(let score) = candidate.element, score < best.score else { return }
            best = (candidate.offset, score)
        }.index
    }

    private func sourceGrids(for channels: [String: Double], weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: channels[condition.rawValue]!))
        })
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
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected

    func targetHasEveryActiveCondition(for weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { target.channels[$0.rawValue] != nil }
    }
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case number(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}
