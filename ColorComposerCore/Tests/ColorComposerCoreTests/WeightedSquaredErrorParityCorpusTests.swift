import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorAndSelectionMatchCommittedParityCorpus() throws {
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
        let palette = try scenario.palette.map(makePaletteColor)
        let target = TargetResponseVector(try lightingChannels(from: scenario.target.channels))
        let weights = try makeWeights(scenario.weights)
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), scenario.id)
        for expectedScore in scenario.expected.scores {
            assert(actualScores[expectedScore.index], matches: expectedScore.score, scenario: scenario.id)
        }

        let selectedByScore = selectedIndex(from: actualScores)
        XCTAssertEqual(selectedByScore, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(tiedIndices(in: actualScores), scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(scenario.expected.tieBroke, scenario.expected.tiedIndices.count > 1, scenario.id)

        guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else {
            return
        }

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let error = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), error, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
    }

    private func assert(_ actual: ScorerResult, matches expected: CorpusScore, scenario: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let expected)):
            XCTAssertEqual(actual, expected, scenario)
        default:
            XCTFail("Expected \(expected) but received \(actual) for \(scenario)")
        }
    }

    private func selectedIndex(from scores: [ScorerResult]) -> Int? {
        scores.enumerated().reduce(into: (index: Int?.none, score: Double.infinity)) { best, item in
            guard case .score(let score) = item.element, score < best.score else { return }
            best = (item.offset, score)
        }.index
    }

    private func tiedIndices(in scores: [ScorerResult]) -> [Int] {
        guard let best = scores.compactMap(scoreValue).min() else { return [] }
        return scores.enumerated().compactMap { index, result in
            scoreValue(result) == best ? index : nil
        }
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
    }

    private func makePaletteColor(_ vector: CorpusVector) throws -> PaletteColor {
        let responses = try lightingChannels(from: vector.channels).mapValues {
            IlluminationResponse(brightness: $0)
        }
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor))
        return PaletteColor(id: vector.index ?? -1, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private func makeWeights(_ weights: [String: Double]) throws -> ChannelWeights {
        let channels = try lightingChannels(from: weights.filter { LightingCondition(rawValue: $0.key) != nil })
        return ChannelWeights(
            white: channels[.white] ?? 0,
            red: channels[.red] ?? 0,
            green: channels[.green] ?? 0,
            blue: channels[.blue] ?? 0,
            lps: channels[.lps] ?? 0
        )
    }

    private func lightingChannels(from channels: [String: Double]) throws -> [LightingCondition: Double] {
        try Dictionary(uniqueKeysWithValues: channels.map { key, value in
            guard let condition = LightingCondition(rawValue: key) else {
                throw ParityCorpusError.unknownLightingCondition(key)
            }
            return (condition, value)
        })
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WeightedSquaredErrorParity/corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private enum ParityCorpusError: Error {
    case unknownLightingCondition(String)
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
    let palette: [CorpusVector]
    let target: CorpusVector
    let weights: [String: Double]
    let expected: ExpectedResult
}

private struct CorpusVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ExpectedResult: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable, CustomStringConvertible {
    case value(Double)
    case excluded

    var description: String {
        switch self {
        case .value(let value): return String(value)
        case .excluded: return "excluded"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}
