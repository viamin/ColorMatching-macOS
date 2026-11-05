import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let palette = try scenario.palette.map(makePaletteColor)
        let target = TargetResponseVector(try responses(for: scenario.target.channels))
        let weights = makeWeights(scenario.weights)
        let scorer = WeightedSquaredErrorScorer()

        let actualScores = scenario.expected.scores.map { expectedScore in
            let actual = scorer.score(
                candidate: palette[expectedScore.index],
                target: target,
                weights: weights
            )
            XCTAssertEqual(actual, expectedScore.score, "scenario: \(scenario.id), candidate: \(expectedScore.index)")
            return actual
        }
        XCTAssertEqual(bestIndex(in: actualScores), scenario.expected.selectedIndex, "scenario: \(scenario.id)")

        if targetHasValues(for: weights, target: target) {
            let result = try CompositionSolver().solve(
                palette: palette,
                sourceGrids: try sourceGrids(for: target, weights: weights),
                weights: weights
            )
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "scenario: \(scenario.id)")
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, "scenario: \(scenario.id)")
            } else {
                XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, "scenario: \(scenario.id)")
            }
        }

        let selectedIndices = scenario.expected.scores.compactMap { score in
            score.score == .score(scenario.expected.error ?? .infinity) ? score.index : nil
        }
        XCTAssertEqual(selectedIndices, scenario.expected.tiedIndices, "scenario: \(scenario.id)")
        let tieBroke = scenario.expected.selectedIndex == nil ? nil : selectedIndices.count > 1
        XCTAssertEqual(scenario.expected.tieBroke, tieBroke, "scenario: \(scenario.id)")
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Parity/v1/corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ entry: ParityEntry) throws -> PaletteColor {
        PaletteColor(
            id: try XCTUnwrap(entry.index),
            hex: entry.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: entry.hexColor)),
            responses: try responses(for: entry.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responses(for channels: [String: Double]) throws -> [LightingCondition: Double] {
        try channels.reduce(into: [:]) { responses, channel in
            responses[try XCTUnwrap(LightingCondition(rawValue: channel.key))] = channel.value
        }
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func sourceGrids(
        for target: TargetResponseVector,
        weights: ChannelWeights
    ) throws -> [LightingCondition: BrightnessGrid] {
        try Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [try XCTUnwrap(target.value(for: condition))]))
        })
    }

    private func targetHasValues(for weights: ChannelWeights, target: TargetResponseVector) -> Bool {
        weights.activeConditions.allSatisfy { target.value(for: $0) != nil }
    }

    private func bestIndex(in scores: [ScorerResult]) -> Int? {
        scores.enumerated().reduce(into: (index: Int?, score: Double.infinity)) { best, candidate in
            if case .score(let score) = candidate.element, score < best.score {
                best = (candidate.offset, score)
            }
        }.index
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case selection
        case missingPolicy = "missing_policy"
        case scenarios
    }
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityEntry
    let palette: [ParityEntry]
    let expected: ParityExpected
}

private struct ParityEntry: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ScorerResult

    enum CodingKeys: String, CodingKey {
        case index
        case score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        if let value = try? container.decode(Double.self, forKey: .score) {
            score = .score(value)
        } else {
            guard try container.decode(String.self, forKey: .score) == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .score,
                    in: container,
                    debugDescription: "Expected a score number or \\"excluded\\"."
                )
            }
            score = .excluded
        }
    }
}
