import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorScorerReplaysParityCorpusExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = weights(from: scenario.weights)
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let palette = try scenario.palette.sorted { $0.index < $1.index }.map(color(from:))
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, scenario.id)
            default:
                XCTFail("\(scenario.id): score did not match exclusion policy")
            }
        }

        let selection = selectedIndex(from: actualScores)
        XCTAssertEqual(selection, scenario.expected.selectedIndex, scenario.id)
        try assertSolverSelection(
            palette: palette,
            target: target,
            weights: weights,
            expected: scenario.expected,
            scenarioID: scenario.id
        )

        if let selectedIndex = scenario.expected.selectedIndex {
            let selected = try XCTUnwrap(selection)
            XCTAssertEqual(palette[selected].hex, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(scoreValue(actualScores[selected]), scenario.expected.error, scenario.id)
        } else {
            XCTAssertNil(selection, scenario.id)
            XCTAssertNil(scenario.expected.error, scenario.id)
        }

        let tiedIndices = tiedIndices(in: actualScores, at: scenario.expected.error)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func color(from entry: ParityVector) throws -> PaletteColor {
        PaletteColor(
            id: try XCTUnwrap(entry.index),
            hex: entry.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: entry.hexColor)),
            responses: responses(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func assertSolverSelection(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        expected: ParityExpected,
        scenarioID: String
    ) throws {
        let active = weights.activeConditions
        guard active.allSatisfy({ target.value(for: $0) != nil }) else { return }
        let grids = try Dictionary(uniqueKeysWithValues: active.map { condition in
            let brightness = try XCTUnwrap(target.value(for: condition))
            return (condition, BrightnessGrid(width: 1, height: 1, values: [brightness]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expected.selectedIndex, scenarioID)
        if let error = expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), error, scenarioID)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenarioID)
        }
    }

    private func selectedIndex(from scores: [ScorerResult]) -> Int? {
        var best: (index: Int, error: Double)?
        for (index, score) in scores.enumerated() {
            guard case .score(let error) = score else { continue }
            if best == nil || error < best!.error {
                best = (index, error)
            }
        }
        return best?.index
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
    }

    private func tiedIndices(in scores: [ScorerResult], at error: Double?) -> [Int] {
        guard let error else { return [] }
        return scores.enumerated().compactMap { index, score in
            scoreValue(score) == error ? index : nil
        }
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
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let scores: [ParityScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let score = try? value.decode(Double.self) {
            self = .value(score)
        } else if try value.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Expected a score or excluded")
        }
    }
}
