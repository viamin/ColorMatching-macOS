import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try decodeCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(
        _ scenario: ParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let target = TargetResponseVector(responses(for: scenario.target.channels))
        let weights = channelWeights(from: scenario.weights)
        let palette = try scenario.palette.map(makePaletteColor)
        let scorer = WeightedSquaredErrorScorer()

        for expectedScore in scenario.expected.scores {
            let actual = scorer.score(
                candidate: palette[expectedScore.index],
                target: target,
                weights: weights
            )
            XCTAssertEqual(actual, expectedScore.score.scorerResult, "scenario: \(scenario.id)", file: file, line: line)
        }

        let scoredSelection = select(scorer: scorer, palette: palette, target: target, weights: weights)
        XCTAssertEqual(scoredSelection.index, scenario.expected.selectedIndex, "scenario: \(scenario.id)", file: file, line: line)
        XCTAssertEqual(scoredSelection.error, scenario.expected.error, "scenario: \(scenario.id)", file: file, line: line)
        XCTAssertEqual(scoredSelection.tiedIndices, scenario.expected.tiedIndices, "scenario: \(scenario.id)", file: file, line: line)
        if let tieBroke = scenario.expected.tieBroke {
            XCTAssertEqual(scoredSelection.tiedIndices.count > 1, tieBroke, "scenario: \(scenario.id)", file: file, line: line)
        }
        XCTAssertEqual(
            scoredSelection.index.map { palette[$0].hex },
            scenario.expected.selectedHexColor,
            "scenario: \(scenario.id)",
            file: file,
            line: line
        )

        guard targetHasMeasurements(target, for: weights) else { return }
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids(from: target, weights: weights),
            weights: weights
        )

        XCTAssertEqual(result.colorIndices, [scenario.expected.selectedIndex], "scenario: \(scenario.id)", file: file, line: line)
        XCTAssertEqual(result.errors, [scenario.expected.error ?? .infinity], "scenario: \(scenario.id)", file: file, line: line)
    }

    private func decodeCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ vector: ParityCorpus.Vector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor))
        return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: rgb, responses: responses(for: vector.channels))
    }

    private func responses(for channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, brightness in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func targetHasMeasurements(
        _ target: TargetResponseVector,
        for weights: ChannelWeights
    ) -> Bool {
        weights.activeEntries.allSatisfy { target.value(for: $0.condition) != nil }
    }

    private func sourceGrids(
        from target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeEntries.map { entry in
            (entry.condition, BrightnessGrid(width: 1, height: 1, fill: target.value(for: entry.condition) ?? 0))
        })
    }

    private func select(
        scorer: WeightedSquaredErrorScorer,
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> (index: Int?, error: Double?, tiedIndices: [Int]) {
        var bestIndex: Int?
        var bestError: Double?
        var tiedIndices: [Int] = []

        for (index, color) in palette.enumerated() {
            guard case .score(let score) = scorer.score(candidate: color, target: target, weights: weights) else { continue }
            if bestError == nil || score < bestError! {
                bestIndex = index
                bestError = score
                tiedIndices = [index]
            } else if score == bestError {
                tiedIndices.append(index)
            }
        }
        return (bestIndex, bestError, tiedIndices)
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    struct Vector: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [ExpectedScore]
        let selectedIndex: Int?
        let selectedHexColor: String?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: Score
    }

    enum Score: Decodable {
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
            case .score(let score): .score(score)
            case .excluded: .excluded
            }
        }
    }
}
