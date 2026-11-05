import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testReplaysCommittedV1CorpusExactly() throws {
        let corpus = try decodeCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = weights(from: scenario.weights)
        let target = TargetResponseVector(channels(from: scenario.target.channels))
        let palette = try scenario.palette.map(makePaletteColor)
        let scorer = WeightedSquaredErrorScorer()
        let results = palette.map {
            scorer.score(candidate: $0, target: target, weights: weights)
        }

        XCTAssertEqual(results.count, scenario.expected.scores.count, scenario.id)
        for expectedScore in scenario.expected.scores.sorted(by: { $0.index < $1.index }) {
            let actual = try XCTUnwrap(results[safe: expectedScore.index], scenario.id)
            XCTAssertEqual(actual, expectedScore.score.scorerResult, scenario.id)
        }

        guard weights.activeConditions.allSatisfy({ scenario.target.channels[$0.rawValue] != nil }) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            XCTAssertNil(scenario.expected.error, scenario.id)
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, scenario.id)
            return
        }

        let sourceGrids = Dictionary(
            uniqueKeysWithValues: weights.activeConditions.map { condition in
                (
                    condition,
                    BrightnessGrid(
                        width: 1,
                        height: 1,
                        values: [scenario.target.channels[condition.rawValue] ?? 0]
                    )
                )
            }
        )
        let solution = try CompositionSolver().solve(
            palette: palette,
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(solution.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let selectedIndex = scenario.expected.selectedIndex {
            let expectedError = try XCTUnwrap(scenario.expected.error, scenario.id)
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(solution.error(x: 0, y: 0), expectedError, scenario.id)
        } else {
            XCTAssertTrue(solution.error(x: 0, y: 0).isInfinite, scenario.id)
        }

        if let expectedError = scenario.expected.error {
            let expectedTieBroke = try XCTUnwrap(scenario.expected.tieBroke, scenario.id)
            let actualTieIndices = results.enumerated().compactMap { index, result -> Int? in
                guard case .score(let score) = result, score == expectedError else {
                    return nil
                }
                return index
            }
            XCTAssertEqual(actualTieIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(actualTieIndices.count > 1, expectedTieBroke, scenario.id)
            if let selectedIndex = scenario.expected.selectedIndex {
                XCTAssertEqual(actualTieIndices.first, selectedIndex, scenario.id)
            }
        } else {
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            XCTAssertTrue(scenario.expected.tiedIndices.isEmpty, scenario.id)
        }
    }

    private func decodeCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: candidate.hexColor), candidate.hexColor)
        return PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: rgb,
            responses: channels(from: candidate.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func channels(from encoded: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: encoded.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func weights(from encoded: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: encoded["white"] ?? 0,
            red: encoded["red"] ?? 0,
            green: encoded["green"] ?? 0,
            blue: encoded["blue"] ?? 0,
            lps: encoded["lps"] ?? 0
        )
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
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
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
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), string == "excluded" {
            self = .excluded
        } else {
            self = .score(try container.decode(Double.self))
        }
    }

    var scorerResult: ScorerResult {
        switch self {
        case .excluded:
            return .excluded
        case .score(let value):
            return .score(value)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
