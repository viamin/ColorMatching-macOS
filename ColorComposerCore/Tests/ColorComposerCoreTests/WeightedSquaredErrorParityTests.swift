import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedParityCorpusMetadataIsSupported() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    func testWeightedSquaredErrorScorerReplaysEveryCommittedParityScenario() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let weights = channelWeights(from: scenario.weights)
            let target = targetVector(from: scenario.target)
            let palette = scenario.palette.map(makePaletteColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (index, pair) in zip(actualScores, scenario.expected.scores).enumerated() {
                let (actual, expected) = pair
                XCTAssertEqual(expected.index, index, scenario.id)
                assertScore(actual, equals: expected.score, scenarioID: scenario.id, index: expected.index)
            }

            assertSelection(
                for: scenario,
                palette: palette,
                target: target,
                weights: weights,
                scores: actualScores
            )
        }
    }

    private func assertSelection(
        for scenario: ParityScenario,
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scores: [ScorerResult]
    ) {
        let bestIndices = scores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result,
                  let expectedError = scenario.expected.error,
                  score == expectedError
            else { return nil }
            return index
        }

        XCTAssertEqual(bestIndices, scenario.expected.tiedIndices, scenario.id)

        guard let expectedIndex = scenario.expected.selectedIndex,
              let expectedError = scenario.expected.error
        else {
            XCTAssertTrue(bestIndices.isEmpty, scenario.id)
            XCTAssertNil(scenario.expected.selectedHexColor, scenario.id)
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            return
        }

        XCTAssertEqual(scenario.expected.tieBroke ?? false, bestIndices.count > 1, scenario.id)
        XCTAssertEqual(bestIndices.first, expectedIndex, scenario.id)
        XCTAssertEqual(palette[expectedIndex].hex, scenario.expected.selectedHexColor ?? "", scenario.id)

        guard targetHasEveryActiveChannel(target, weights: weights) else { return }

        do {
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(from: target, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id)
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
        } catch {
            XCTFail("\(scenario.id): unexpected solver error \(error)")
        }
    }

    private func assertScore(
        _ actual: ScorerResult,
        equals expected: ParityScore,
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

    private func targetHasEveryActiveChannel(_ target: TargetResponseVector, weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { target.value(for: $0) != nil }
    }

    private func sourceGrids(
        from target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.compactMap { condition in
            target.value(for: condition).map { (condition, BrightnessGrid(width: 1, height: 1, values: [$0])) }
        })
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func targetVector(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(lightingValues(from: vector.channels))
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: lightingValues(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func lightingValues(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
            values[condition.rawValue].map { (condition, $0) }
        })
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_parity_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
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
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityIndexedScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityIndexedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return "score(\(value))"
        }
    }
}
