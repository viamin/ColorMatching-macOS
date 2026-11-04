import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysCommittedV1CorpusExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels.conditions)
        let palette = try scenario.palette.map(PaletteColor.init(vector:))
        let scored = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(scored.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(scored, scenario.expected.scores) {
            XCTAssertEqual(actual, expected.result, "\(scenario.id): candidate \(expected.index)")
        }

        assertSelection(scored, palette: palette, scenario: scenario)

        if weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) {
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: targetGrids(for: target, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .infinity, scenario.id)
        }
    }

    private func targetGrids(
        for target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition) ?? 0]))
        })
    }

    private func assertSelection(
        _ scores: [ScorerResult],
        palette: [PaletteColor],
        scenario: ParityScenario
    ) {
        let best = scores.enumerated().reduce(into: (index: Int?, error: Double.infinity)) { best, entry in
            guard case .score(let score) = entry.element, score < best.error else { return }
            best = (entry.offset, score)
        }
        let actualIndex = best.index
        XCTAssertEqual(actualIndex, scenario.expected.selectedIndex, scenario.id)

        guard let selectedIndex = scenario.expected.selectedIndex,
              let expectedError = scenario.expected.error,
              let expectedHex = scenario.expected.selectedHexColor
        else {
            XCTAssertTrue(best.error.isInfinite, scenario.id)
            XCTAssertEqual(scenario.expected.tiedIndices, [])
            XCTAssertNil(scenario.expected.tieBroke)
            return
        }

        XCTAssertEqual(palette[selectedIndex].hex, expectedHex, scenario.id)
        XCTAssertEqual(best.error, expectedError, scenario.id)

        let ties = scenario.expected.scores.compactMap { score -> Int? in
            score.result == .score(expectedError) ? score.index : nil
        }
        XCTAssertEqual(ties, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, ties.count > 1, scenario.id)
        XCTAssertEqual(ties.first, selectedIndex, scenario.id)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
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
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
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
            let marker = try container.decode(String.self, forKey: .score)
            guard marker == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a score or the excluded marker."
                )
            }
            result = .excluded
        }
    }
}

private extension Dictionary where Key == String, Value == Double {
    var conditions: [LightingCondition: Double] {
        reduce(into: [:]) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}

private extension PaletteColor {
    init(vector: ParityVector) throws {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw ParityFixtureError.invalidHex(vector.hexColor)
        }
        self.init(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: rgb,
            responses: vector.channels.conditions.mapValues { IlluminationResponse(brightness: $0) }
        )
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
}
