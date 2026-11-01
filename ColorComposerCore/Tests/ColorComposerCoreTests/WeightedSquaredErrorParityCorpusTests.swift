import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testV1CorpusMatchesWeightedSquaredErrorSelection() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.scenarios.count, 12)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses: scenario.target.channels)
            let weights = ChannelWeights(responses: scenario.weights)
            let palette = try scenario.palette.map { try PaletteColor(vector: $0) }

            let actualScores = palette.map {
                scorer.score(candidate: $0, target: target, weights: weights)
            }
            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), "Unexpected candidate order for \(scenario.id)")
            XCTAssertEqual(
                actualScores,
                scenario.expected.scores.map(ScorerResult.init),
                "Unexpected candidate scores for \(scenario.id)"
            )

            let selection = selectEarliestMinimum(from: actualScores)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, "Unexpected selection for \(scenario.id)")
            assertEqual(selection.error, scenario.expected.error, scenario: scenario.id)

            let tiedIndices = actualScores.enumerated().compactMap { index, score -> Int? in
                guard case .score(let value) = score, value == selection.error else { return nil }
                return index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "Unexpected tie set for \(scenario.id)")
            if let tieBroke = scenario.expected.tieBroke {
                XCTAssertEqual(tiedIndices.count > 1, tieBroke, "Unexpected tie policy for \(scenario.id)")
            } else {
                XCTAssertNil(selection.index, "Unexpected tie policy for \(scenario.id)")
            }

            if let selectedIndex = selection.index {
                XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, "Unexpected color for \(scenario.id)")
            }
        }
    }

    private func assertEqual(_ actual: Double?, _ expected: Double?, scenario: String) {
        switch (actual, expected) {
        case let (.some(actual), .some(expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "Unexpected error for \(scenario)")
        case (.none, .none):
            break
        default:
            XCTFail("Unexpected error for \(scenario): \(String(describing: actual))")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func selectEarliestMinimum(from scores: [ScorerResult]) -> (index: Int?, error: Double?) {
        var index: Int?
        var error: Double?
        for candidate in scores.enumerated() {
            guard case .score(let score) = candidate.element else { continue }
            if error == nil || score < error! {
                index = candidate.offset
                error = score
            }
        }
        return (index, error)
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]

    private enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case selection
        case missingPolicy = "missing_policy"
        case scenarios
    }

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    struct Vector: Decodable {
        let channels: [String: Double]
        let hexColor: String
        let index: Int?

        private enum CodingKeys: String, CodingKey {
            case channels
            case hexColor = "hex_color"
            case index
        }
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [CandidateScore]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]

        private enum CodingKeys: String, CodingKey {
            case error, scores
            case selectedHexColor = "selected_hex_color"
            case selectedIndex = "selected_index"
            case tieBroke = "tie_broke"
            case tiedIndices = "tied_indices"
        }
    }

    struct CandidateScore: Decodable {
        let index: Int
        let score: Score
    }

    enum Score: Decodable {
        case value(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else {
                let value = try container.decode(String.self)
                guard value == "excluded" else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score \(value)")
                }
                self = .excluded
            }
        }
    }
}

private extension TargetResponseVector {
    init(responses: [String: Double]) {
        self.init(Dictionary(uniqueKeysWithValues: responses.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        }))
    }
}

private extension ChannelWeights {
    init(responses: [String: Double]) {
        self.init(
            white: responses["white"] ?? 0,
            red: responses["red"] ?? 0,
            green: responses["green"] ?? 0,
            blue: responses["blue"] ?? 0,
            lps: responses["lps"] ?? 0
        )
    }
}

private extension PaletteColor {
    init(vector: ParityCorpus.Vector) throws {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw ParityCorpusError.invalidHex(vector.hexColor)
        }
        self.init(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: rgb,
            responses: Dictionary(uniqueKeysWithValues: vector.channels.compactMap { key, value in
                LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
            })
        )
    }
}

private extension ScorerResult {
    init(_ score: ParityCorpus.CandidateScore) {
        switch score.score {
        case .value(let value): self = .score(value)
        case .excluded: self = .excluded
        }
    }
}

private enum ParityCorpusError: Error {
    case invalidHex(String)
}
