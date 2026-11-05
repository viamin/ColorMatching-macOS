import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysVersionOneCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = channelWeights(from: scenario.weights)
        let target = target(from: scenario.target)
        let palette = scenario.palette
            .sorted { $0.index < $1.index }
            .map(paletteColor(from:))
        let expected = scenario.expected
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map {
            scorer.score(candidate: $0, target: target, weights: weights)
        }

        XCTAssertEqual(actualScores, expected.scores.sorted { $0.index < $1.index }.map(\.scorerResult), scenario.id)

        let selected = selectedIndex(in: actualScores)
        XCTAssertEqual(selected, expected.selectedIndex, scenario.id)

        if let selected {
            guard case .score(let error) = actualScores[selected] else {
                return XCTFail("\(scenario.id): selected candidate was excluded")
            }
            guard let expectedError = expected.error else {
                return XCTFail("\(scenario.id): selected candidate has no expected error")
            }
            guard let expectedHexColor = expected.selectedHexColor else {
                return XCTFail("\(scenario.id): selected candidate has no expected hex color")
            }
            XCTAssertEqual(error, expectedError, scenario.id)
            XCTAssertEqual(palette[selected].hex, expectedHexColor, scenario.id)
        }

        let tiedIndices = tiedIndices(in: actualScores, selected: selected)
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenario.id)
        XCTAssertEqual(tiedIndices.count > 1, expected.tieBroke ?? false, scenario.id)

        try assertSolverSelection(
            scenario,
            palette: palette,
            weights: weights,
            expectedSelection: selected
        )
    }

    private func assertSolverSelection(
        _ scenario: ParityScenario,
        palette: [PaletteColor],
        weights: ChannelWeights,
        expectedSelection: Int?
    ) throws {
        let active = weights.activeConditions
        guard active.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else {
            return
        }

        let grids = Dictionary(uniqueKeysWithValues: active.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[condition.rawValue]!]))
        })
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: grids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedSelection, scenario.id)
        if expectedSelection != nil, let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
    }

    private func selectedIndex(in scores: [ScorerResult]) -> Int? {
        scores.enumerated().reduce(into: (index: Int?, score: Double.infinity)) { best, candidate in
            guard case .score(let score) = candidate.element, score < best.score else { return }
            best = (candidate.offset, score)
        }.index
    }

    private func tiedIndices(in scores: [ScorerResult], selected: Int?) -> [Int] {
        guard let selected, case .score(let selectedScore) = scores[selected] else { return [] }
        return scores.enumerated().compactMap {
            guard case .score(let score) = $0.element, score == selectedScore else { return nil }
            return $0.offset
        }
    }

    private func channelWeights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
    }

    private func target(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(responses(from: vector))
    }

    private func paletteColor(from vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from vector: ParityVector) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
            vector.channels[condition.rawValue].map { (condition, $0) }
        })
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let path = testDirectory
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: path))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let lightSources: [String]
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let result: ParityScoreResult

    enum CodingKeys: String, CodingKey {
        case index
        case result = "score"
    }

    var scorerResult: ScorerResult {
        switch result {
        case .excluded: return .excluded
        case .score(let value): return .score(value)
        }
    }
}

private enum ParityScoreResult: Decodable {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
            }
            self = .excluded
        }
    }
}
