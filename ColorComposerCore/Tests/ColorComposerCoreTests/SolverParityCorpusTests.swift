import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the versioned golden vectors published by `color_matching`.
///
/// The fixture deliberately covers exact ties, exclusions for missing positive-
/// weight measurements, and ignored zero-weight measurements. Keep it in sync
/// with `color_matching/priv/parity/v1/corpus.json`.
final class SolverParityCorpusTests: XCTestCase {
    func testFixtureDeclaresTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerAndSolverReplayEveryCorpusScenario() throws {
        for scenario in try loadCorpus().scenarios {
            let palette = try scenario.palette
                .sorted { ($0.index ?? -1) < ($1.index ?? -1) }
                .map(makePaletteColor)
            let target = makeTargetVector(from: scenario.target.channels)
            let weights = makeWeights(from: scenario.weights)
            let scoreResults = palette.map {
                WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights)
            }

            XCTAssertEqual(scoreResults.count, scenario.expected.scores.count, scenario.id)
            for (index, expected) in scenario.expected.scores.sorted(by: { $0.index < $1.index }).enumerated() {
                XCTAssertEqual(expected.index, index, scenario.id)
                assert(scoreResults[index], matches: expected.score, scenarioID: scenario.id, index: index)
            }

            let selectedByScores = selectedIndex(from: scoreResults)
            XCTAssertEqual(selectedByScores, scenario.expected.selectedIndex, scenario.id)
            if let selectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
            }
            assertTieEvidence(
                scoreResults,
                expected: scenario.expected,
                scenarioID: scenario.id
            )

            let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
                (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
            })
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: sourceGrids,
                weights: weights
            )

            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
            }
        }
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ExpectedScore,
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

    private func assertTieEvidence(
        _ scores: [ScorerResult],
        expected: CorpusExpected,
        scenarioID: String
    ) {
        guard let selectedIndex = expected.selectedIndex, let error = expected.error else {
            XCTAssertNil(expected.tieBroke, scenarioID)
            XCTAssertEqual(expected.tiedIndices, [], scenarioID)
            return
        }

        let tiedIndices = scores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == error else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenarioID)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, scenarioID)
        XCTAssertEqual(tiedIndices.first, selectedIndex, scenarioID)
    }

    private func selectedIndex(from scores: [ScorerResult]) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    private func makePaletteColor(_ vector: CorpusVector) throws -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
        })
        return PaletteColor(
            id: try XCTUnwrap(vector.index),
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func makeTargetVector(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }))
    }

    private func makeWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights[LightingCondition.white.rawValue] ?? 0,
            red: weights[LightingCondition.red.rawValue] ?? 0,
            green: weights[LightingCondition.green.rawValue] ?? 0,
            blue: weights[LightingCondition.blue.rawValue] ?? 0,
            lps: weights[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: url))
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let lightSources: [String]
    let scenarios: [CorpusScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer, selection
        case missingPolicy = "missing_policy"
        case lightSources = "light_sources"
        case scenarios
    }
}

private struct CorpusScenario: Decodable {
    let id: String
    let palette: [CorpusVector]
    let target: CorpusVector
    let weights: [String: Double]
    let expected: CorpusExpected
}

private struct CorpusVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct CorpusExpected: Decodable {
    let error: Double?
    let scores: [CorpusScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedIndex = "selected_index"
        case selectedHexColor = "selected_hex_color"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct CorpusScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable, CustomStringConvertible {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var description: String {
        switch self {
        case .score(let score): return "score(\(score))"
        case .excluded: return "excluded"
        }
    }
}
