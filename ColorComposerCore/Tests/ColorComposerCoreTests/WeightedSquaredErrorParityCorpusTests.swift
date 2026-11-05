import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCommittedV1CorpusReplaysExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertFalse(corpus.scenarios.isEmpty)

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(
        _ scenario: ParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let weights = channelWeights(from: scenario.weights)
        let target = targetVector(from: scenario.target)
        let palette = scenario.palette.sorted { $0.index < $1.index }.map(paletteColor(from:))
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id, file: file, line: line)
        for (actual, expected) in zip(actualScores, scenario.expected.scores) {
            assertScore(actual, equals: expected.score, scenarioID: scenario.id, file: file, line: line)
        }

        let selectedIndex = actualScores.enumerated().first(where: { _, score in
            guard case .score = score else { return false }
            let best = actualScores.compactMap(scoreValue).min()
            return scoreValue(score) == best
        })?.offset
        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id, file: file, line: line)

        let tiedIndices = actualScores.enumerated().compactMap { index, score -> Int? in
            guard let selectedIndex,
                  let selectedScore = scoreValue(actualScores[selectedIndex]),
                  scoreValue(score) == selectedScore
            else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id, file: file, line: line)
        if selectedIndex == nil {
            XCTAssertNil(scenario.expected.tieBroke, scenario.id, file: file, line: line)
        } else {
            let expectedTieBroke = try XCTUnwrap(scenario.expected.tieBroke, scenario.id, file: file, line: line)
            XCTAssertEqual(
                tiedIndices.count > 1,
                expectedTieBroke,
                scenario.id,
                file: file,
                line: line
            )
        }

        guard let selectedIndex, let expectedError = scenario.expected.error else {
            XCTAssertNil(scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
            return
        }

        XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id, file: file, line: line)
        XCTAssertEqual(scoreValue(actualScores[selectedIndex]), expectedError, scenario.id, file: file, line: line)

        if targetHasEveryActiveChannel(target: scenario.target, weights: weights) {
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(from: scenario.target, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, scenario.id, file: file, line: line)
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id, file: file, line: line)
        }
    }

    private func assertScore(
        _ actual: ScorerResult,
        equals expected: ParityCorpus.Score,
        scenarioID: String,
        file: StaticString,
        line: UInt
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, scenarioID, file: file, line: line)
        default:
            XCTFail("\(scenarioID): expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
    }

    private func paletteColor(from vector: ParityCorpus.Vector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector)
        )
    }

    private func targetVector(from vector: ParityCorpus.Vector) -> TargetResponseVector {
        TargetResponseVector(
            Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
                LightingCondition(rawValue: key).map { ($0, value) }
            })
        )
    }

    private func responses(from vector: ParityCorpus.Vector) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
        })
    }

    private func channelWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func targetHasEveryActiveChannel(target: ParityCorpus.Vector, weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { target.channels[$0.rawValue] != nil }
    }

    private func sourceGrids(
        from target: ParityCorpus.Vector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.compactMap { condition in
            target.channels[condition.rawValue].map {
                (condition, BrightnessGrid(width: 1, height: 1, values: [$0]))
            }
        })
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let palette: [Vector]
        let target: Vector
        let weights: [String: Double]
        let expected: Expected
    }

    struct Vector: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int?
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [IndexedScore]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct IndexedScore: Decodable {
        let index: Int
        let score: Score
    }

    enum Score: Decodable, CustomStringConvertible {
        case excluded
        case value(Double)

        var description: String {
            switch self {
            case .excluded: return "excluded"
            case .value(let value): return String(value)
            }
        }

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
}
