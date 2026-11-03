import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testReplaysPinnedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        for scenario in corpus.scenarios {
            try assertScoresMatch(scenario)
            try assertSelectionMatches(scenario)
        }
    }

    private func assertScoresMatch(
        _ scenario: ParityScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = weights(from: scenario.weights)

        for expected in scenario.expected.scores {
            let candidate = try XCTUnwrap(
                scenario.palette.first(where: { $0.index == expected.index }),
                "Missing candidate \(expected.index) in \(scenario.id)",
                file: file,
                line: line
            )
            switch (scorer.score(candidate: color(from: candidate), target: target, weights: weights), expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .number(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenario.id), candidate \(candidate.index)", file: file, line: line)
            default:
                XCTFail("\(scenario.id), candidate \(candidate.index): scorer result differs from corpus", file: file, line: line)
            }
        }
    }

    private func assertSelectionMatches(
        _ scenario: ParityScenario,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let weights = weights(from: scenario.weights)
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let palette = scenario.palette.map(color(from:))
        let scored = palette.map { WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights) }

        let tied = scored.enumerated().compactMap { index, result -> Int? in
            guard let expectedError = scenario.expected.error,
                  case .score(let score) = result,
                  score == expectedError
            else { return nil }
            return index
        }
        XCTAssertEqual(tied, scenario.expected.tiedIndices, "\(scenario.id)", file: file, line: line)

        guard weights.activeConditions.allSatisfy({ target.value(for: $0) != nil }) else {
            XCTAssertNil(scenario.expected.selectedIndex, "\(scenario.id) has an incomplete target", file: file, line: line)
            return
        }

        let grids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, values: [target.value(for: condition)!]))
        })
        let result = try CompositionSolver().solve(palette: palette, sourceGrids: grids, weights: weights)
        XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, "\(scenario.id)", file: file, line: line)

        if let expectedError = scenario.expected.error {
            XCTAssertEqual(result.error(x: 0, y: 0), expectedError, accuracy: 1e-12, "\(scenario.id)", file: file, line: line)
        }
        if scenario.expected.tieBroke == true {
            XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.tiedIndices.first, "\(scenario.id) must retain earliest-wins tie-breaking", file: file, line: line)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: file))
    }

    private func color(from candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: responses(from: candidate.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
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
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case number(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}
