import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysCommittedServerParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let palette = try scenario.palette
            .sorted { $0.index < $1.index }
            .map(makePaletteColor)
        let target = makeTarget(scenario.target)
        let weights = makeWeights(scenario.weights)
        let scorer = WeightedSquaredErrorScorer()
        let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }

        XCTAssertEqual(palette.count, expectedScores.count, scenario.id)
        for (index, expected) in expectedScores.enumerated() {
            XCTAssertEqual(expected.index, index, scenario.id)
            XCTAssertEqual(
                scorer.score(candidate: palette[index], target: target, weights: weights),
                expected.result,
                scenario.id
            )
        }

        guard targetHasEveryActiveChannel(scenario.target, weights: weights) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            XCTAssertNil(scenario.expected.error, scenario.id)
            XCTAssertTrue(expectedScores.allSatisfy { $0.result == .excluded }, scenario.id)
            return
        }

        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids(target: scenario.target, weights: weights),
            weights: weights
        )
        assertSelection(result, scenario: scenario)
    }

    private func assertSelection(_ result: CompositionResult, scenario: ParityScenario) {
        let expected = scenario.expected
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expected.selectedIndex, scenario.id)

        guard let selectedIndex = expected.selectedIndex, let error = expected.error else {
            XCTAssertNil(result.colorIndex(x: 0, y: 0), scenario.id)
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            XCTAssertEqual(expected.tieBroke, nil, scenario.id)
            XCTAssertEqual(expected.tiedIndices, [], scenario.id)
            return
        }

        XCTAssertEqual(result.error(x: 0, y: 0), error, scenario.id)
        let tiedIndices = expected.scores.compactMap { score -> Int? in
            score.result == .score(error) ? score.index : nil
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenario.id)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, scenario.id)
        XCTAssertEqual(selectedIndex, tiedIndices.first, scenario.id)
    }

    private func sourceGrids(target: ParityVector, weights: ChannelWeights) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.channels[condition.rawValue]!]))
        })
    }

    private func targetHasEveryActiveChannel(_ target: ParityVector, weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { target.channels[$0.rawValue] != nil }
    }

    private func makePaletteColor(_ vector: ParityVector) throws -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses(from: vector.channels)
        )
    }

    private func makeTarget(_ vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(responses(from: vector.channels).mapValues(\.brightness))
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, brightness in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: brightness)) }
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

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
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
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let result: ScorerResult

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let score = try? container.decode(Double.self, forKey: .score) {
            result = .score(score)
        } else {
            let value = try container.decode(String.self, forKey: .score)
            guard value == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a numeric score or excluded, got \\(value)"
                )
            }
            result = .excluded
        }
    }
}
