import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the server-owned golden vectors committed from
/// `viamin/color_matching#111`. The fixture intentionally exercises the
/// solver contracts that are easiest to drift: positive-weight exclusions,
/// zero-weight omissions, exact scores, and earliest-index tie breaking.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = scenario.weights.channelWeights
            let target = TargetResponseVector(scenario.target.responses)
            let palette = try scenario.palette.map { try $0.paletteColor }
            let scores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(scores.count, scenario.expected.scores.count, scenario.id)
            for expectedScore in scenario.expected.scores {
                XCTAssertEqual(scores[expectedScore.index], expectedScore.score.scorerResult, scenario.id)
            }

            assertTieEvidence(scenario.expected, actualScores: scores, scenarioID: scenario.id)
            try assertSolverSelectionWhenTargetIsComplete(
                scenario: scenario,
                palette: palette,
                weights: weights
            )
        }
    }

    private func assertTieEvidence(
        _ expected: Expected,
        actualScores: [ScorerResult],
        scenarioID: String
    ) {
        let finiteScores = actualScores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        guard let best = finiteScores.map(\.1).min() else {
            XCTAssertNil(expected.selectedIndex, scenarioID)
            XCTAssertNil(expected.error, scenarioID)
            XCTAssertTrue(expected.tiedIndices.isEmpty, scenarioID)
            return
        }

        let tiedIndices = finiteScores.filter { $0.1 == best }.map(\.0)
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenarioID)
        XCTAssertEqual(tiedIndices.count > 1, expected.tieBroke, scenarioID)
        XCTAssertEqual(tiedIndices.first, expected.selectedIndex, scenarioID)
        XCTAssertEqual(best, expected.error, accuracy: 1e-12, scenarioID)
    }

    private func assertSolverSelectionWhenTargetIsComplete(
        scenario: Scenario,
        palette: [PaletteColor],
        weights: ChannelWeights
    ) throws {
        guard weights.activeConditions.allSatisfy({ scenario.target.responses[$0] != nil }) else { return }
        let grids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [scenario.target.responses[$0]!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let error = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), error, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Corpus.self, from: Data(contentsOf: fixture))
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [ParityColor]
    let target: ParityColor
    let weights: ParityWeights
    let expected: Expected
}

private struct ParityColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    var responses: [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
    }

    var paletteColor: PaletteColor {
        get throws {
            guard let rgb = RGBColor(hex: hexColor) else {
                throw ParityFixtureError.invalidHex(hexColor)
            }
            return PaletteColor(
                id: index ?? 0,
                hex: hexColor,
                rgb: rgb,
                responses: responses.mapValues { IlluminationResponse(brightness: $0) }
            )
        }
    }
}

private struct ParityWeights: Decodable {
    let channels: [String: Double]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        channels = try container.decode([String: Double].self)
    }

    var channelWeights: ChannelWeights {
        ChannelWeights(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected excluded score")
            }
            self = .excluded
        }
    }

    var scorerResult: ScorerResult {
        switch self {
        case .score(let value): return .score(value)
        case .excluded: return .excluded
        }
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
}
