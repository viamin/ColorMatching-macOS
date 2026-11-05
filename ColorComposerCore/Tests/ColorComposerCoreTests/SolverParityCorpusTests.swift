import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the versioned golden vectors published by color_matching.
///
/// Keep the fixture byte-for-byte in sync with
/// https://github.com/viamin/color_matching/blob/main/priv/parity/v1/corpus.json.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = try scenario.palette.map(makePaletteColor)

            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
            assertScores(actualScores, match: scenario.expected.scores, scenarioID: scenario.id)

            let selected = earliestBestIndex(in: actualScores)
            XCTAssertEqual(selected, scenario.expected.selectedIndex, "scenario: \(scenario.id)")
            XCTAssertEqual(selected.map { palette[$0].hex }, scenario.expected.selectedHexColor, "scenario: \(scenario.id)")

            let bestError = selected.flatMap { scoreValue(actualScores[$0]) }
            XCTAssertEqual(bestError, scenario.expected.error, "scenario: \(scenario.id)")
            XCTAssertEqual(tiedIndices(in: actualScores, bestError: bestError), scenario.expected.tiedIndices, "scenario: \(scenario.id)")

            if let sourceGrids = sourceGrids(from: scenario.target.channels, weights: weights) {
                let result = try CompositionSolver().solve(
                    palette: palette,
                    sourceGrids: sourceGrids,
                    weights: weights
                )
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "scenario: \(scenario.id)")
                XCTAssertEqual(result.errors[0], scenario.expected.error ?? .infinity, "scenario: \(scenario.id)")
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: file))
    }

    private func makePaletteColor(_ fixture: ParityPaletteColor) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: fixture.hexColor), "Invalid corpus hex: \(fixture.hexColor)")
        return PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: rgb,
            responses: responses(from: fixture.channels)
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func weights(from fixture: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: fixture["white", default: 0],
            red: fixture["red", default: 0],
            green: fixture["green", default: 0],
            blue: fixture["blue", default: 0],
            lps: fixture["lps", default: 0]
        )
    }

    /// The solver cannot receive a target with a missing active source grid;
    /// those corpus scenarios are still covered directly through the scorer.
    private func sourceGrids(
        from target: [String: Double],
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid]? {
        var grids: [LightingCondition: BrightnessGrid] = [:]
        for condition in weights.activeConditions {
            guard let value = target[condition.rawValue] else { return nil }
            grids[condition] = BrightnessGrid(width: 1, height: 1, values: [value])
        }
        return grids
    }

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [ParityScore],
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "scenario: \(scenarioID)", file: file, line: line)
        for (index, expectation) in expected.enumerated() {
            XCTAssertEqual(expectation.index, index, "scenario: \(scenarioID)", file: file, line: line)
            switch (actual[index], expectation.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, "scenario: \(scenarioID), candidate: \(index)", file: file, line: line)
            default:
                XCTFail("scenario: \(scenarioID), candidate: \(index)", file: file, line: line)
            }
        }
    }

    private func earliestBestIndex(in scores: [ScorerResult]) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard let score = scoreValue(result) else { continue }
            if best == nil || score < best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    private func tiedIndices(in scores: [ScorerResult], bestError: Double?) -> [Int] {
        guard let bestError else { return [] }
        return scores.enumerated().compactMap { index, result in
            scoreValue(result) == bestError ? index : nil
        }
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
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
    let palette: [ParityPaletteColor]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityPaletteColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case excluded
    case value(Double)

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
