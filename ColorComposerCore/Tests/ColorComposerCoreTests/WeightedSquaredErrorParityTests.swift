import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testParityCorpusMatchesScoresSelectionsAndTieBreaks() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makePaletteColor)
            let target = targetVector(from: scenario.target.channels)
            let weights = channelWeights(from: scenario.weights)
            let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(Array(palette.indices), scenario.palette.map(\.index), scenario.id)
            XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id)
            for (index, pair) in zip(scores, scenario.expected.scores).enumerated() {
                let (actual, expected) = pair
                XCTAssertEqual(expected.index, index, scenario.id)
                assert(actual, matches: expected.score, scenario: scenario.id, index: expected.index)
            }

            let selectedIndex = scores.enumerated().compactMap { index, score -> Int? in
                guard case .score = score else { return nil }
                return index
            }.min { lhs, rhs in
                guard case .score(let left) = scores[lhs], case .score(let right) = scores[rhs] else {
                    return false
                }
                return left < right
            }

            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            if let selectedIndex, case .score(let score) = scores[selectedIndex] {
                let expectedError = try XCTUnwrap(scenario.expected.error, scenario.id)
                let expectedHexColor = try XCTUnwrap(scenario.expected.selectedHexColor, scenario.id)
                let expectedTieBroke = try XCTUnwrap(scenario.expected.tieBroke, scenario.id)
                XCTAssertEqual(score, expectedError, accuracy: 1e-12, scenario.id)
                XCTAssertEqual(palette[selectedIndex].hex, expectedHexColor, scenario.id)

                let tiedIndices = scores.enumerated().compactMap { index, candidate -> Int? in
                    guard case .score(let candidateScore) = candidate, candidateScore == score else { return nil }
                    return index
                }
                XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
                XCTAssertEqual(tiedIndices.count > 1, expectedTieBroke, scenario.id)
                assertSolverSelection(
                    scenario: scenario,
                    palette: palette,
                    weights: weights,
                    expectedIndex: selectedIndex,
                    expectedError: score
                )
            } else {
                XCTAssertNil(scenario.expected.error, scenario.id)
                XCTAssertNil(scenario.expected.selectedHexColor, scenario.id)
                XCTAssertEqual(scenario.expected.tiedIndices, [], scenario.id)
            }
        }
    }

    private func assertSolverSelection(
        scenario: Scenario,
        palette: [PaletteColor],
        weights: ChannelWeights,
        expectedIndex: Int,
        expectedError: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let active = weights.activeConditions
        guard active.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else { return }
        let sourceGrids = Dictionary(uniqueKeysWithValues: active.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[$0.rawValue]!]))
        })

        do {
            let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, scenario.id, file: file, line: line)
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id, file: file, line: line)
        } catch {
            XCTFail("\\(scenario.id): solver threw \\(error)", file: file, line: line)
        }
    }

    private func assert(_ actual: ScorerResult, matches expected: ScoreValue, scenario: String, index: Int) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\\(scenario), candidate \\(index)")
        default:
            XCTFail("\\(scenario), candidate \\(index): expected \\(expected), got \\(actual)")
        }
    }

    private func loadCorpus() throws -> Corpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ vector: Vector) throws -> PaletteColor {
        let responses = try Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
        })
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func targetVector(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }))
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
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [Vector]
    let target: Vector
    let weights: [String: Double]
    let expected: Expected
}

private struct Vector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: ScoreValue
}

private enum ScoreValue: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let score): return "\\(score)"
        }
    }
}
