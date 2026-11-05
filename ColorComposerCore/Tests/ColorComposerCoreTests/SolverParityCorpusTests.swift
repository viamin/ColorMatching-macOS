import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(makeChannels(scenario.target.channels))
            let palette = scenario.palette.map(makeColor)
            let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(
                scores,
                scenario.expected.scores.map(\.scorerResult),
                "Score mismatch for corpus scenario \(scenario.id)"
            )
            XCTAssertEqual(
                scenario.expected.scores.map(\.index),
                Array(palette.indices),
                "Corpus score indices must match palette order for \(scenario.id)"
            )

            let scoredIndices = scores.enumerated().compactMap { index, result -> Int? in
                guard case .score = result else { return nil }
                return index
            }
            let selectedIndex = scoredIndices.min { lhs, rhs in
                guard case .score(let left) = scores[lhs], case .score(let right) = scores[rhs] else {
                    return false
                }
                return left < right
            }

            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, "Selection mismatch for \(scenario.id)")
            XCTAssertEqual(selectedIndex.map { palette[$0].hex }, scenario.expected.selectedHexColor)
            XCTAssertEqual(
                selectedIndex.flatMap { index in
                    guard case .score(let value) = scores[index] else { return nil }
                    return value
                },
                scenario.expected.error,
                "Error mismatch for corpus scenario \(scenario.id)"
            )

            let tiedIndices = scores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let value) = result, value == scenario.expected.error else { return nil }
                return index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "Tie evidence mismatch for \(scenario.id)")
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1 ? true : scenario.expected.tieBroke)

            if let expectedIndex = scenario.expected.selectedIndex {
                let grids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
                    (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
                })
                let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, "Solver selection mismatch for \(scenario.id)")
                XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error, "Solver error mismatch for \(scenario.id)")
            } else {
                XCTAssertTrue(scores.allSatisfy {
                    if case .excluded = $0 { return true }
                    return false
                }, "Unselected corpus scenario must exclude every candidate: \(scenario.id)")
            }
        }
    }

    private func loadCorpus() throws -> Corpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent().appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ fixture: PaletteFixture) -> PaletteColor {
        PaletteColor(
            id: fixture.index ?? 0,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: makeChannels(fixture.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func makeChannels(_ channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [PaletteFixture]
    let target: PaletteFixture
    let weights: [String: Double]
    let expected: Expected
}

private struct PaletteFixture: Decodable {
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

    var scorerResult: ScorerResult {
        switch score {
        case .value(let value): return .score(value)
        case .excluded: return .excluded
        }
    }
}

private enum ScoreValue: Decodable {
    case value(Double)
    case excluded

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
}
