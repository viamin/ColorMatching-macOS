import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
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
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(channels: scenario.target.channels)
        let palette = try scenario.palette
            .sorted { $0.index < $1.index }
            .map(PaletteColor.init(parityVector:))
        let expectedScores = scenario.expected.scores.sorted { $0.index < $1.index }
        let scorer = WeightedSquaredErrorScorer()

        XCTAssertEqual(palette.count, expectedScores.count, scenario.id)

        let scores = zip(palette, expectedScores).map { color, expected in
            let actual = scorer.score(candidate: color, target: target, weights: weights)
            XCTAssertEqual(actual, expected.result, "\(scenario.id): candidate \(expected.index)")
            return actual
        }

        assertSelection(
            scores: scores,
            palette: palette,
            expected: scenario.expected,
            scenarioID: scenario.id
        )

        if hasMeasuredTarget(for: weights, channels: scenario.target.channels) {
            try assertSolverSelection(
                palette: palette,
                targetChannels: scenario.target.channels,
                weights: weights,
                expected: scenario.expected,
                scenarioID: scenario.id
            )
        }
    }

    private func assertSelection(
        scores: [ScorerResult],
        palette: [PaletteColor],
        expected: Expected,
        scenarioID: String
    ) {
        let selectable = scores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        guard let minimum = selectable.map(\.1).min() else {
            XCTAssertNil(expected.selectedIndex, scenarioID)
            XCTAssertNil(expected.error, scenarioID)
            XCTAssertTrue(expected.tiedIndices.isEmpty, scenarioID)
            XCTAssertNil(expected.tieBroke, scenarioID)
            return
        }

        let tiedIndices = selectable.filter { $0.1 == minimum }.map(\.0)
        let selectedIndex = tiedIndices[0]

        XCTAssertEqual(selectedIndex, expected.selectedIndex, scenarioID)
        XCTAssertEqual(minimum, expected.error, scenarioID)
        XCTAssertEqual(palette[selectedIndex].hex, expected.selectedHexColor, scenarioID)
        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenarioID)
        XCTAssertEqual(tiedIndices.count > 1, expected.tieBroke, scenarioID)
    }

    private func assertSolverSelection(
        palette: [PaletteColor],
        targetChannels: [String: Double],
        weights: ChannelWeights,
        expected: Expected,
        scenarioID: String
    ) throws {
        let sourceGrids = Dictionary(
            uniqueKeysWithValues: weights.activeConditions.map { condition in
                (condition, BrightnessGrid(width: 1, height: 1, fill: targetChannels[condition.rawValue]!))
            }
        )
        let result = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expected.selectedIndex, scenarioID)
        XCTAssertEqual(result.error(x: 0, y: 0), expected.error, scenarioID)
    }

    private func hasMeasuredTarget(for weights: ChannelWeights, channels: [String: Double]) -> Bool {
        weights.activeConditions.allSatisfy { channels[$0.rawValue] != nil }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SolverParity/v1/corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
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
    let palette: [IndexedParityVector]
    let expected: Expected
}

private struct ParityVector: Decodable {
    let hexColor: String
    let channels: [String: Double]
}

private struct IndexedParityVector: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let result: ScorerResult

    private enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let score = try? container.decode(Double.self, forKey: .score) {
            result = .score(score)
        } else {
            guard try container.decode(String.self, forKey: .score) == "excluded" else {
                throw ParityFixtureError.invalidScore
            }
            result = .excluded
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }
}

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(Dictionary(
            uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
                channels[condition.rawValue].map { (condition, $0) }
            }
        ))
    }
}

private extension PaletteColor {
    init(parityVector vector: IndexedParityVector) throws {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw ParityFixtureError.invalidHex(vector.hexColor)
        }
        let responses = Dictionary(
            uniqueKeysWithValues: LightingCondition.all.compactMap { condition in
                vector.channels[condition.rawValue].map { (condition, IlluminationResponse(brightness: $0)) }
            }
        )
        self.init(id: vector.index, hex: vector.hexColor, rgb: rgb, responses: responses)
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
    case invalidScore
}
