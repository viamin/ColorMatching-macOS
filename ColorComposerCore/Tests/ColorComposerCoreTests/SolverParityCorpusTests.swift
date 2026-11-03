import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataDescribesTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.scores.contains { $0.score == .excluded } })
    }

    func testWeightedSquaredErrorReplaysEveryParityScenario() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = scenario.channelWeights
            let target = scenario.targetResponse
            let palette = try scenario.palette
                .sorted { ($0.index ?? -1) < ($1.index ?? -1) }
                .map(makePaletteColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores, scenario.expected.scorerResultsByIndex, scenario.id)

            guard scenario.hasMeasurementsForEveryActiveTargetChannel else { continue }
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: scenario.sourceGrids,
                weights: weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }

            let tiedIndices = actualScores.enumerated().compactMap { index, result in
                result == .score(scenario.expected.error ?? .infinity) ? index : nil
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            if let tieBroke = scenario.expected.tieBroke {
                XCTAssertEqual(tieBroke, tiedIndices.count > 1, scenario.id)
            } else {
                XCTAssertTrue(tiedIndices.isEmpty, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid fixture color \(vector.hexColor)")
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: rgb,
            responses: vector.responses
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    var targetResponse: TargetResponseVector {
        TargetResponseVector(target.brightness)
    }

    var hasMeasurementsForEveryActiveTargetChannel: Bool {
        channelWeights.activeConditions.allSatisfy { target.brightness[$0] != nil }
    }

    var sourceGrids: [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: channelWeights.activeConditions.compactMap { condition in
            target.brightness[condition].map { (condition, BrightnessGrid(width: 1, height: 1, values: [$0])) }
        })
    }
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    var brightness: [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    var responses: [LightingCondition: IlluminationResponse] {
        brightness.mapValues { IlluminationResponse(brightness: $0) }
    }
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    var scorerResultsByIndex: [ScorerResult] {
        scores.sorted { $0.index < $1.index }.map(\.scorerResult)
    }
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable, Equatable {
    case excluded
    case value(Double)

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

    var scorerResult: ScorerResult {
        switch self {
        case .excluded: .excluded
        case .value(let value): .score(value)
        }
    }
}
