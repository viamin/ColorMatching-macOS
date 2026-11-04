import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the server-owned golden vectors so the Swift implementation cannot
/// drift from `ColorMatching.WeightedSquaredError` unnoticed.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testVersionOneCorpusMatchesScoresAndSelectionsExactly() throws {
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
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = ChannelWeights(channels: scenario.weights)
        let palette = try scenario.palette.map(makeColor)

        for expectedScore in scenario.expected.scores {
            let actual = scorer.score(
                candidate: palette[expectedScore.index], target: target, weights: weights
            )
            assert(actual, equals: expectedScore.score, scenario: scenario.id, index: expectedScore.index)
        }

        guard scenario.targetHasEveryActiveChannel(weights) else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            XCTAssertNil(scenario.expected.error, scenario.id)
            return
        }

        let sources = Dictionary(uniqueKeysWithValues: weights.activeConditions.map {
            ($0, BrightnessGrid(width: 1, height: 1, values: [target.value(for: $0)!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: sources, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error ?? .infinity, accuracy: 1e-12, scenario.id)
        if let selectedIndex = scenario.expected.selectedIndex {
            XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
        }
    }

    private func assert(_ actual: ScorerResult, equals expected: ParityScore, scenario: String, index: Int) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario), candidate \(index)")
        default:
            XCTFail("\(scenario), candidate \(index): expected \(expected), got \(actual)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: candidate.hexColor)),
            responses: responses(from: candidate.channels).mapValues(IlluminationResponse.init(brightness:))
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
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityTarget
    let weights: [String: Double]
    let expected: ParityExpected

    func targetHasEveryActiveChannel(_ weights: ChannelWeights) -> Bool {
        weights.activeConditions.allSatisfy { target.channels[$0.rawValue] != nil }
    }
}

private struct ParityCandidate: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityTarget: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case score(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }

    var description: String {
        switch self {
        case .score(let value): return "score(\(value))"
        case .excluded: return "excluded"
        }
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}
