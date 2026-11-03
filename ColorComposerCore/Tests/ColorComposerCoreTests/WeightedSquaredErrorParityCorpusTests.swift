import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testMatchesVersionOneCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let target = responseVector(from: scenario.target.channels)
        let weights = channelWeights(from: scenario.weights)
        let palette = try scenario.palette.enumerated().map { index, entry in
            let rgb = try XCTUnwrap(RGBColor(hex: entry.hexColor))
            return PaletteColor(
                id: index,
                hex: entry.hexColor,
                rgb: rgb,
                responses: entry.channels.mapValues { IlluminationResponse(brightness: $0) }
            )
        }

        for expectedScore in scenario.expected.scores {
            let result = WeightedSquaredErrorScorer().score(
                candidate: palette[expectedScore.index], target: target, weights: weights
            )
            assert(result, equals: expectedScore.score, scenario: scenario.id, index: expectedScore.index)
        }

        // `CompositionSolver` constructs a value for every active source grid,
        // so a corpus case whose target is missing an active channel can only
        // exercise the scorer's exclusion contract above.
        guard scenario.expected.selectedIndex != nil else { return }

        let grids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: target.value(for: condition)!))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)

        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertTrue(result.error(x: 0, y: 0).isInfinite, scenario.id)
        }
    }

    private func assert(_ result: ScorerResult, equals expected: ParityScore, scenario: String, index: Int) {
        switch (result, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario), candidate \(index)")
        default:
            XCTFail("\(scenario), candidate \(index): expected \(expected), received \(result)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1-corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: source))
    }

    private func responseVector(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }))
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
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
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedIndex: Int?
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case score(Double)
    case excluded

    var description: String {
        switch self {
        case .score(let value): return "score(\(value))"
        case .excluded: return "excluded"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}
