import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataRecordsTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    func testWeightedSquaredErrorAndSelectionMatchParityCorpus() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let palette = scenario.palette.sorted { $0.index < $1.index }.map(makeColor)
            let target = TargetResponseVector(responseVector(from: scenario.target.channels))
            let weights = makeWeights(scenario.weights)
            let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }

            XCTAssertEqual(palette.count, expectedScores.count, scenario.id)
            for (candidate, expected) in zip(palette, expectedScores) {
                assert(
                    scorer.score(candidate: candidate, target: target, weights: weights),
                    matches: expected.score,
                    scenario: scenario.id,
                    candidate: expected.index
                )
            }

            // A missing target cannot be represented by source grids, but is
            // still checked above through the scorer. Every other corpus case
            // is replayed through the production solver to cover selection.
            guard scenario.target.hasEveryPositiveWeight(in: scenario.weights) else { continue }

            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids(for: scenario.target.channels, weights: scenario.weights),
                weights: weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(result.excludedCandidateCount, expectedScores.count(where: { $0.score == .excluded }), scenario.id)

            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
                XCTAssertEqual(result.palette[try XCTUnwrap(scenario.expected.selectedIndex)].hex, scenario.expected.selectedHexColor, scenario.id)

                let tied = expectedScores.compactMap { entry -> Int? in
                    guard case .value(let score) = entry.score, score == expectedError else { return nil }
                    return entry.index
                }
                XCTAssertEqual(tied, scenario.expected.tiedIndices, scenario.id)
                XCTAssertEqual(scenario.expected.tieBroke, Optional(tied.count > 1), scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
                XCTAssertNil(scenario.expected.tieBroke, scenario.id)
                XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ entry: ParityVector) -> PaletteColor {
        PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: responseVector(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responseVector(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
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

    private func sourceGrids(
        for channels: [String: Double], weights: [String: Double]
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.compactMap { name, weight in
            guard weight > 0, let condition = LightingCondition(rawValue: name), let value = channels[name] else {
                return nil
            }
            return (condition, BrightnessGrid(width: 1, height: 1, values: [value]))
        })
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenario: String,
        candidate: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario), candidate \(candidate)")
        default:
            XCTFail("\(scenario), candidate \(candidate): expected \(expected), got \(actual)")
        }
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

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScoreEntry]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScoreEntry: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable, CustomStringConvertible {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .value(score)
            return
        }
        if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected excluded or a numeric score"
            )
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .value(let score): return String(score)
        }
    }
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    func hasEveryPositiveWeight(in weights: [String: Double]) -> Bool {
        weights.allSatisfy { name, weight in
            weight <= 0 || LightingCondition(rawValue: name) == nil || channels[name] != nil
        }
    }
}
