import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the v1 golden vectors published by `color_matching`.
///
/// Refresh the committed fixture from
/// `color_matching/priv/parity/v1/corpus.json` whenever its
/// `algorithm_version` changes. This catches divergence in weighted scores,
/// exclusions, and earliest-index-wins selection.
final class WeightedSquaredErrorParityTests: XCTestCase {
    private let scorer = WeightedSquaredErrorScorer()

    func testCorpusMetadataDescribesTheSupportedAlgorithm() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorMatchesEveryPublishedParityScenario() throws {
        let corpus = try loadCorpus()

        for scenario in corpus.scenarios {
            try assertScoresMatch(scenario)
            try assertSelectionMatches(scenario)
        }
    }

    private func assertScoresMatch(
        _ scenario: ParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let weights = channelWeights(from: scenario.weights)
        let target = targetVector(from: scenario.target)
        let expectedScores = Dictionary(uniqueKeysWithValues: scenario.expected.scores.map { ($0.index, $0.score) })

        for candidate in scenario.palette {
            guard let candidateIndex = candidate.index else {
                return XCTFail("\(scenario.id): palette candidate has no index", file: file, line: line)
            }
            let actual = scorer.score(candidate: paletteColor(from: candidate), target: target, weights: weights)
            guard let expected = expectedScores[candidateIndex] else {
                return XCTFail("\(scenario.id): missing expected score for candidate \(candidateIndex)", file: file, line: line)
            }
            assert(actual, matches: expected, scenarioID: scenario.id, candidateIndex: candidateIndex, file: file, line: line)
        }
    }

    private func assertSelectionMatches(
        _ scenario: ParityCorpus.Scenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let weights = channelWeights(from: scenario.weights)
        let target = targetVector(from: scenario.target)

        guard let expectedIndex = scenario.expected.selectedIndex else {
            for candidate in scenario.palette {
                XCTAssertEqual(
                    scorer.score(candidate: paletteColor(from: candidate), target: target, weights: weights),
                    .excluded,
                    "\(scenario.id): expected candidate \(String(describing: candidate.index)) to be excluded",
                    file: file,
                    line: line
                )
            }
            return
        }
        let expectedError = try XCTUnwrap(scenario.expected.error, "\(scenario.id): selected result must have an error")

        let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
        })
        let result = try CompositionSolver().solve(
            palette: scenario.palette.map(paletteColor),
            sourceGrids: sourceGrids,
            weights: weights
        )

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), expectedIndex, "\(scenario.id)", file: file, line: line)
        XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, "\(scenario.id)", file: file, line: line)
        XCTAssertEqual(
            result.palette[expectedIndex].hex,
            scenario.expected.selectedHexColor,
            "\(scenario.id)",
            file: file,
            line: line
        )
        XCTAssertEqual(tiedIndices(in: scenario, target: target, weights: weights), scenario.expected.tiedIndices, "\(scenario.id)", file: file, line: line)
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ParityCorpus.ScoreValue,
        scenarioID: String,
        candidateIndex: Int,
        file: StaticString,
        line: UInt
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .number(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenarioID): candidate \(candidateIndex)", file: file, line: line)
        default:
            XCTFail("\(scenarioID): candidate \(candidateIndex) did not match expected \(expected)", file: file, line: line)
        }
    }

    private func tiedIndices(
        in scenario: ParityCorpus.Scenario,
        target: TargetResponseVector,
        weights: ChannelWeights
    ) -> [Int] {
        guard let minimum = scenario.expected.error else { return [] }
        return scenario.palette.compactMap { candidate in
            guard case .score(let score) = scorer.score(candidate: paletteColor(from: candidate), target: target, weights: weights),
                  score == minimum
            else { return nil }
            return candidate.index
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func channelWeights(from weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white", default: 0],
            red: weights["red", default: 0],
            green: weights["green", default: 0],
            blue: weights["blue", default: 0],
            lps: weights["lps", default: 0]
        )
    }

    private func targetVector(from entry: ParityCorpus.Entry) -> TargetResponseVector {
        TargetResponseVector(responses(from: entry.channels))
    }

    private func paletteColor(from entry: ParityCorpus.Entry) -> PaletteColor {
        PaletteColor(
            id: entry.index ?? 0,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: responses(from: entry.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let selection: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Entry
        let palette: [Entry]
        let expected: Expected
    }

    struct Entry: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int?
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [Score]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct Score: Decodable {
        let index: Int
        let score: ScoreValue
    }

    enum ScoreValue: Decodable, CustomStringConvertible {
        case excluded
        case number(Double)

        var description: String {
            switch self {
            case .excluded: return "excluded"
            case .number(let value): return String(value)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else if try container.decode(String.self) == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
            }
        }
    }
}
