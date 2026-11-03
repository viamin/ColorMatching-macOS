import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the server-owned golden vectors committed by color_matching#111.
///
/// The corpus is deliberately copied into `Resources/parity/v1/` rather than
/// fetched while testing: parity must be reproducible when offline and a server
/// change must arrive as an explicit, reviewable fixture update.
final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesServerParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let candidates = scenario.palette.map(makeColor)
            let actual = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actual.count, scenario.expected.scores.count, scenario.id)
            for (result, expected) in zip(actual, scenario.expected.scores) {
                assert(result, matches: expected.score, scenario: scenario.id, index: expected.index)
            }

            let selected = actual.enumerated().first { result in
                if case .score(let score) = result.element {
                    return score == actual.compactMap(scoreValue).min()
                }
                return false
            }?.offset

            XCTAssertEqual(selected, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selected.map { candidates[$0].hex }, scenario.expected.selectedHexColor, scenario.id)
            if let selected, let expectedError = scenario.expected.error {
                let actualError = try XCTUnwrap(scoreValue(actual[selected]), scenario.id)
                XCTAssertEqual(actualError, expectedError, accuracy: 0, scenario.id)
            } else {
                XCTAssertNil(scenario.expected.error, scenario.id)
            }
        }
    }

    private let scorer = WeightedSquaredErrorScorer()

    private func loadCorpus() throws -> Corpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/parity/v1/corpus.json")
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    private func makeColor(_ vector: ColorVector) -> PaletteColor {
        PaletteColor(
            id: vector.index,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector.channels)
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
        })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0], red: values["red", default: 0],
            green: values["green", default: 0], blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
    }

    private func assert(_ result: ScorerResult, matches expected: ExpectedScore, scenario: String, index: Int) {
        switch (result, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 0, "\(scenario), candidate \(index)")
        default:
            XCTFail("\(scenario), candidate \(index): expected \(expected), received \(result)")
        }
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [ColorVector]
    let target: ColorVector
    let weights: [String: Double]
    let expected: Expected
}

private struct ColorVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
}

private struct ExpectedCandidateScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return String(value)
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
