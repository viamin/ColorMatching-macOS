import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusMetadataDocumentsTheServerContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.scenarios.map(\.id), [
            "distinct-errors",
            "tie-symmetric-around-target",
            "tie-duplicate-vectors",
            "tie-three-way-on-lps",
            "missing-candidate-excluded",
            "missing-target-excluded",
            "zero-weight-channel-missing",
            "all-excluded",
            "single-channel-lps",
            "exact-match-zero-error",
            "unknown-weight-ignored",
            "mixed-large-palette"
        ])
    }

    func testWeightedSquaredErrorMatchesEveryServerCorpusScenario() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let palette = try scenario.palette.map(makePaletteColor)
            let target = try makeTarget(scenario.target)
            let weights = makeWeights(scenario.weights)
            let expected = scenario.expected

            var selectedIndex: Int?
            var selectedError = Double.infinity

            for (index, candidate) in palette.enumerated() {
                let actual = CorpusScore(scorer.score(candidate: candidate, target: target, weights: weights))
                XCTAssertEqual(index, scenario.palette[index].index, "scenario: \(scenario.id)")
                XCTAssertEqual(actual, expected.scores[index].score, "scenario: \(scenario.id), candidate: \(index)")

                if case .score(let score) = actual, score < selectedError {
                    selectedError = score
                    selectedIndex = index
                }
            }

            XCTAssertEqual(selectedIndex, expected.selectedIndex, "scenario: \(scenario.id)")
            if let selectedIndex {
                XCTAssertEqual(palette[selectedIndex].hex, expected.selectedHexColor, "scenario: \(scenario.id)")
                XCTAssertEqual(selectedError, try XCTUnwrap(expected.error), accuracy: 0, "scenario: \(scenario.id)")
            } else {
                XCTAssertNil(expected.error, "scenario: \(scenario.id)")
            }

            let expectedTieIndices = expected.scores.compactMap { score in
                score.score == .score(selectedError) ? score.index : nil
            }
            XCTAssertEqual(expectedTieIndices, expected.tiedIndices, "scenario: \(scenario.id)")
            XCTAssertEqual(expectedTieIndices.count > 1, expected.tieBroke, "scenario: \(scenario.id)")
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ vector: CorpusVector) throws -> PaletteColor {
        let responses = try vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { responses, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            responses[condition] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(
            id: try XCTUnwrap(vector.index),
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func makeTarget(_ vector: CorpusVector) throws -> TargetResponseVector {
        let brightness = vector.channels.reduce(into: [LightingCondition: Double]()) { brightness, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            brightness[condition] = entry.value
        }
        return TargetResponseVector(brightness)
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values[LightingCondition.white.rawValue] ?? 0,
            red: values[LightingCondition.red.rawValue] ?? 0,
            green: values[LightingCondition.green.rawValue] ?? 0,
            blue: values[LightingCondition.blue.rawValue] ?? 0,
            lps: values[LightingCondition.lps.rawValue] ?? 0
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [CorpusVector]
    let target: CorpusVector
    let weights: [String: Double]
    let expected: ExpectedOutcome
}

private struct CorpusVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ExpectedOutcome: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Equatable, Decodable {
    case excluded
    case score(Double)

    init(_ result: ScorerResult) {
        switch result {
        case .excluded: self = .excluded
        case .score(let score): self = .score(score)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
            }
            self = .excluded
        }
    }
}

private extension ParityCorpus {
    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case missingPolicy = "missing_policy"
        case scorer
        case selection
        case scenarios
    }
}

private extension CorpusVector {
    enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private extension ExpectedOutcome {
    enum CodingKeys: String, CodingKey {
        case error
        case scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}
