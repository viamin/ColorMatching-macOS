import Foundation
import XCTest
@testable import ColorComposerCore

final class ParityCorpusTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    func testCorpusMetadataDescribesTheSharedWeightedSquaredErrorContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertEqual(corpus.scenarios.count, 12)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerReplaysEveryCorpusScenarioExactly() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let palette = try scenario.palette.sorted { ($0.index ?? -1) < ($1.index ?? -1) }.map(makePaletteColor)
        let target = makeTarget(from: scenario.target)
        let weights = makeWeights(from: scenario.weights)
        let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }

        XCTAssertEqual(palette.count, expectedScores.count, scenario.id)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        for (actual, expected) in zip(actualScores, expectedScores) {
            assertScore(
                actual,
                equals: expected.score,
                scenarioID: scenario.id,
                index: expected.index
            )
        }

        guard targetContainsEveryActiveCondition(target, weights: weights) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            return
        }

        let tiedIndices = actualScores.enumerated().compactMap { index, score -> Int? in
            guard let expectedError = scenario.expected.error,
                  case .score(let value) = score,
                  value == expectedError
            else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids(from: target, weights: weights),
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let selectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(result.error(x: 0, y: 0), try XCTUnwrap(scenario.expected.error), scenario.id)
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
        } else {
            XCTAssertEqual(result.error(x: 0, y: 0), .infinity, scenario.id)
        }
    }

    private func assertScore(
        _ actual: ScorerResult,
        equals expected: ExpectedScore,
        scenarioID: String,
        index: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, "\(scenarioID), candidate \(index)")
        default:
            XCTFail("\(scenarioID), candidate \(index): expected \(expected), got \(actual)")
        }
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        PaletteColor(
            id: try XCTUnwrap(vector.index),
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responseMap(from: vector.channels)
        )
    }

    private func makeTarget(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(channelMap(from: vector.channels))
    }

    private func makeWeights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white", default: 0],
            red: encoded["red", default: 0],
            green: encoded["green", default: 0],
            blue: encoded["blue", default: 0],
            lps: encoded["lps", default: 0]
        )
    }

    private func responseMap(from encoded: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        channelMap(from: encoded).mapValues(IlluminationResponse.init(brightness:))
    }

    private func channelMap(from encoded: [String: Double]) -> [LightingCondition: Double] {
        encoded.reduce(into: [:]) { channels, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            channels[condition] = entry.value
        }
    }

    private func targetContainsEveryActiveCondition(_ target: TargetResponseVector, weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { target.value(for: $0) != nil }
    }

    private func sourceGrids(
        from target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: target.value(for: condition)!))
        })
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpectedResult
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpectedResult: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown expected score")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return String(value)
        }
    }
}
