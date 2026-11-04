import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesWeightedSquaredErrorSelectionAndScores() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = makeWeights(from: scenario.weights)
        let target = makeTarget(from: scenario.target)
        let palette = try scenario.palette.enumerated().map { index, entry in
            try makeColor(entry, id: index)
        }

        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }
        XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), scenario.id)
        XCTAssertEqual(actualScores, scenario.expected.scores.map(\.result), scenario.id)

        let selectedIndex = selectLowestScore(from: actualScores)
        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)

        if let selectedIndex {
            XCTAssertEqual(
                palette[selectedIndex].hex,
                try XCTUnwrap(scenario.expected.selectedHexColor),
                scenario.id
            )
            XCTAssertEqual(scoreValue(actualScores[selectedIndex]), scenario.expected.error, scenario.id)
        } else {
            XCTAssertNil(scenario.expected.error, scenario.id)
            XCTAssertNil(scenario.expected.selectedHexColor, scenario.id)
        }

        let tiedIndices = tiedIndices(in: actualScores, selectedIndex: selectedIndex)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id)

        try assertSolverSelection(
            for: scenario,
            palette: palette,
            target: target,
            weights: weights
        )
    }

    private func assertSolverSelection(
        for scenario: ParityScenario,
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights
    ) throws {
        guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else { return }

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

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func makeTarget(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(responses(from: vector.channels))
    }

    private func makeColor(_ vector: ParityVector, id: Int) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus hex color: \(vector.hexColor)")
        return PaletteColor(
            id: id,
            hex: vector.hexColor,
            rgb: rgb,
            responses: responses(from: vector.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func selectLowestScore(from scores: [ScorerResult]) -> Int? {
        var selected: Int?
        var lowest = Double.infinity
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result, score < lowest else { continue }
            selected = index
            lowest = score
        }
        return selected
    }

    private func tiedIndices(in scores: [ScorerResult], selectedIndex: Int?) -> [Int] {
        guard let selectedIndex, let selectedScore = scoreValue(scores[selectedIndex]) else { return [] }
        return scores.indices.filter { scoreValue(scores[$0]) == selectedScore }
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
    let missingPolicy: String
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
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [IndexedParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct IndexedParityScore: Decodable {
    let index: Int
    let score: ParityScore

    var result: ScorerResult { score.result }
}

private enum ParityScore: Decodable {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else {
            let value = try container.decode(String.self)
            guard value == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a numeric score or \"excluded\", received \(value)"
                )
            }
            self = .excluded
        }
    }

    var result: ScorerResult {
        switch self {
        case .excluded: .excluded
        case .score(let value): .score(value)
        }
    }
}
