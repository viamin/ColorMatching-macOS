import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the server-owned golden vectors to prevent Swift/Elixir solver drift.
final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataAndCoverage() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.scores.contains { $0.score == nil } })
    }

    func testWeightedSquaredErrorAndSelectionMatchParityCorpus() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makePaletteColor)
            let target = targetVector(from: scenario.target.channels)
            let weights = channelWeights(from: scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(actualScores, match: scenario.expected.scores, scenario: scenario)
            assertScoredSelection(actualScores, matches: scenario.expected, palette: palette, scenario: scenario)

            guard let sourceGrids = sourceGrids(from: scenario.target.channels, weights: weights) else {
                continue
            }
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )
            assertSolverSelection(result, matches: scenario.expected, palette: palette, scenario: scenario)
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SolverParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ vector: SolverParityCorpus.Vector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw CorpusError.invalidHex(vector.hexColor)
        }
        let responses = vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private func targetVector(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(channels.reduce(into: [LightingCondition: Double]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        })
    }

    private func channelWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func sourceGrids(
        from channels: [String: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid]? {
        let active = weights.activeConditions
        guard active.allSatisfy({ channels[$0.rawValue] != nil }) else { return nil }
        return Dictionary(uniqueKeysWithValues: active.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [channels[condition.rawValue]!]))
        })
    }

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [SolverParityCorpus.ExpectedScore],
        scenario: SolverParityCorpus.Scenario
    ) {
        XCTAssertEqual(actual.count, expected.count, scenario.id)
        for (index, expectedScore) in expected.sorted(by: { $0.index < $1.index }).enumerated() {
            switch (actual[index], expectedScore.score) {
            case (.excluded, nil):
                continue
            case (.score(let actualScore), .some(let expectedScore)):
                XCTAssertEqual(actualScore, expectedScore, accuracy: 0, "\(scenario.id) candidate \(index)")
            default:
                XCTFail("\(scenario.id) candidate \(index): expected \(expectedScore.score.map { String($0) } ?? "excluded"), got \(actual[index])")
            }
        }
    }

    private func assertScoredSelection(
        _ scores: [ScorerResult],
        matches expected: SolverParityCorpus.Expected,
        palette: [PaletteColor],
        scenario: SolverParityCorpus.Scenario
    ) {
        let selected = scores.enumerated().reduce(nil as (index: Int, error: Double)?) { best, candidate in
            guard case .score(let error) = candidate.element else { return best }
            guard let best else { return (candidate.offset, error) }
            return error < best.error ? (candidate.offset, error) : best
        }

        XCTAssertEqual(selected?.index, expected.selectedIndex, scenario.id)
        if let expectedError = expected.error {
            guard let selected else {
                return XCTFail("\(scenario.id): expected a selected candidate")
            }
            XCTAssertEqual(selected.error, expectedError, accuracy: 0, scenario.id)
        } else {
            XCTAssertNil(selected?.error, scenario.id)
        }
        XCTAssertEqual(selected.map { palette[$0.index].hex }, expected.selectedHexColor, scenario.id)
    }

    private func assertSolverSelection(
        _ result: CompositionResult,
        matches expected: SolverParityCorpus.Expected,
        palette: [PaletteColor],
        scenario: SolverParityCorpus.Scenario
    ) {
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expected.selectedIndex, scenario.id)
        XCTAssertEqual(result.excludedCandidateCount, expected.scores.filter { $0.score == nil }.count, scenario.id)

        guard let selectedIndex = expected.selectedIndex else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            XCTAssertNil(expected.tieBroke, scenario.id)
            XCTAssertEqual(expected.tiedIndices, [], scenario.id)
            return
        }
        guard let expectedError = expected.error else {
            return XCTFail("\(scenario.id): selected scenario is missing its expected error")
        }
        guard let expectedHexColor = expected.selectedHexColor else {
            return XCTFail("\(scenario.id): selected scenario is missing its expected hex color")
        }

        XCTAssertEqual(palette[selectedIndex].hex, expectedHexColor, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 0, scenario.id)
        let actualTies = expected.scores.compactMap { score in
            score.score == expectedError ? score.index : nil
        }
        XCTAssertEqual(actualTies, expected.tiedIndices, scenario.id)
        XCTAssertEqual(expected.tieBroke, actualTies.count > 1, scenario.id)
        XCTAssertEqual(actualTies.first, Optional(selectedIndex), scenario.id)
    }
}

private enum CorpusError: Error {
    case invalidHex(String)
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [Scenario]
    let scorer: String
    let selection: String

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
        let scores: [ExpectedScore]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: Double?

        private enum CodingKeys: String, CodingKey {
            case index
            case score
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = try container.decode(Int.self, forKey: .index)
            if try container.decodeNil(forKey: .score) {
                score = nil
            } else if let value = try? container.decode(Double.self, forKey: .score) {
                score = value
            } else {
                let marker = try container.decode(String.self, forKey: .score)
                guard marker == "excluded" else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .score,
                        in: container,
                        debugDescription: "Expected a number or excluded"
                    )
                }
                score = nil
            }
        }
    }
}
