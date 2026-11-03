import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            try assertScoresMatch(scenario)
            try assertSelectionMatches(scenario)
        }
    }

    private func assertScoresMatch(_ scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(responses(in: scenario.target))
        let weights = weights(in: scenario.weights)

        for expectedScore in scenario.expected.scores {
            let candidate = try XCTUnwrap(
                scenario.palette.first(where: { $0.index == expectedScore.index }),
                "Missing candidate \\(expectedScore.index) in scenario \\(scenario.id)"
            )
            let score = scorer.score(
                candidate: paletteColor(candidate),
                target: target,
                weights: weights
            )

            switch (score, expectedScore.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
            default:
                XCTFail("Score mismatch for candidate \\(expectedScore.index) in \\(scenario.id)")
            }
        }
    }

    private func assertSelectionMatches(_ scenario: ParityScenario) throws {
        let weights = weights(in: scenario.weights)
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(responses(in: scenario.target))
        let scores = scenario.palette.map {
            scorer.score(candidate: paletteColor($0), target: target, weights: weights)
        }
        let selectedIndex = firstLowestScoreIndex(in: scores)

        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(
            selectedIndex.flatMap { index in scenario.palette.first(where: { $0.index == index })?.hexColor },
            scenario.expected.selectedHexColor,
            scenario.id
        )

        let tiedIndices = tiedIndices(in: scores)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        if selectedIndex == nil {
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
        } else {
            XCTAssertEqual(try XCTUnwrap(scenario.expected.tieBroke), tiedIndices.count > 1, scenario.id)
        }

        guard let selectedIndex else { return }
        let expectedError = try XCTUnwrap(scenario.expected.error, scenario.id)
        guard case .score(let selectedScore) = scores[selectedIndex] else {
            return XCTFail("Selected candidate is excluded in \\(scenario.id)")
        }
        XCTAssertEqual(selectedScore, expectedError, accuracy: 1e-12, scenario.id)

        guard targetHasEveryActiveCondition(target, weights: weights) else { return }
        let result = try CompositionSolver().solve(
            palette: scenario.palette.map(paletteColor),
            sourceGrids: sourceGrids(in: scenario.target, weights: weights),
            weights: weights
        )
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), selectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
    }

    private func tiedIndices(in scores: [ScorerResult]) -> [Int] {
        let finiteScores = scores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        guard let lowest = finiteScores.map(\.1).min() else { return [] }
        return finiteScores.compactMap { index, score in score == lowest ? index : nil }
    }

    private func firstLowestScoreIndex(in scores: [ScorerResult]) -> Int? {
        var selected: Int?
        var lowest = Double.infinity
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result, score < lowest else { continue }
            lowest = score
            selected = index
        }
        return selected
    }

    private func targetHasEveryActiveCondition(
        _ target: TargetResponseVector,
        weights: ChannelWeights
    ) -> Bool {
        weights.activeConditions.allSatisfy { target.value(for: $0) != nil }
    }

    private func sourceGrids(
        in target: ParityVector,
        weights: ChannelWeights
    ) -> [LightingCondition: BrightnessGrid] {
        Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, fill: target.channels[$0.rawValue]!))
        })
    }

    private func paletteColor(_ color: ParityPaletteColor) -> PaletteColor {
        PaletteColor(
            id: color.index,
            hex: color.hexColor,
            rgb: RGBColor(hex: color.hexColor)!,
            responses: responses(in: color.channels)
                .mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responses(in vector: ParityVector) -> [LightingCondition: Double] {
        responses(in: vector.channels)
    }

    private func responses(in channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func weights(in channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels[LightingCondition.white.rawValue] ?? 0,
            red: channels[LightingCondition.red.rawValue] ?? 0,
            green: channels[LightingCondition.green.rawValue] ?? 0,
            blue: channels[LightingCondition.blue.rawValue] ?? 0,
            lps: channels[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
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
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown score")
        }
    }
}
