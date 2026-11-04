import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the server-owned golden vectors from
/// `viamin/color_matching/priv/parity/v1/corpus.json`. The fixture deliberately
/// remains a plain committed file instead of a SwiftPM resource so test failures
/// identify an absent or stale corpus without changing package production code.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCorpusMatchesWeightedSquaredErrorSelectionsAndScores() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: Scenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(scenario.target.channels)
        let palette = scenario.palette.sorted { $0.index < $1.index }.map(\.paletteColor)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, "scenario: \(scenario.id)")

        for (actual, expected) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 0, "scenario: \(scenario.id), candidate: \(expected.index)")
            default:
                XCTFail("scenario: \(scenario.id), candidate: \(expected.index) score mismatch")
            }
        }

        let ranked = actualScores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        let selected = ranked.min { $0.1 < $1.1 }

        XCTAssertEqual(selected?.0, scenario.expected.selectedIndex, "scenario: \(scenario.id)")
        if let selected {
            XCTAssertEqual(selected.1, try XCTUnwrap(scenario.expected.error), accuracy: 0, "scenario: \(scenario.id)")
            XCTAssertEqual(palette[selected.0].hex, scenario.expected.selectedHexColor, "scenario: \(scenario.id)")
            let tied = ranked.filter { $0.1 == selected.1 }.map(\.0)
            XCTAssertEqual(tied, scenario.expected.tiedIndices, "scenario: \(scenario.id)")
            XCTAssertEqual(tied.count > 1, try XCTUnwrap(scenario.expected.tieBroke), "scenario: \(scenario.id)")
        } else {
            XCTAssertNil(scenario.expected.error, "scenario: \(scenario.id)")
            XCTAssertNil(scenario.expected.tieBroke, "scenario: \(scenario.id)")
        }
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]
    let scorer: String
    let selection: String
}

private struct Scenario: Decodable {
    let expected: Expected
    let id: String
    let palette: [Vector]
    let target: Vector
    let weights: [String: Double]
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
    enum Score: Decodable {
        case excluded
        case value(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else {
                guard try container.decode(String.self) == "excluded" else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an excluded score")
                }
                self = .excluded
            }
        }
    }

    let index: Int
    let score: Score
}

private struct Vector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    var paletteColor: PaletteColor {
        PaletteColor(
            id: index ?? -1,
            hex: hexColor,
            rgb: RGBColor(hex: hexColor)!,
            responses: channels.reduce(into: [:]) { responses, entry in
                guard let condition = LightingCondition(rawValue: entry.key) else { return }
                responses[condition] = IlluminationResponse(brightness: entry.value)
            }
        )
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
