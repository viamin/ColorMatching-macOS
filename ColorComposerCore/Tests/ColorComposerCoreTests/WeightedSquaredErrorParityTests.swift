import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesScoresAndSelectionsExactly() throws {
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(channels(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = scenario.palette.map(paletteColor)
            let expectedScores = Dictionary(uniqueKeysWithValues: scenario.expected.scores.map { ($0.index, $0.score) })
            var selected: (index: Int, score: Double)?

            for candidate in scenario.palette {
                let candidateIndex = try XCTUnwrap(candidate.index, "Palette candidates require an index: \(scenario.id)")
                let result = scorer.score(candidate: paletteColor(candidate), target: target, weights: weights)
                XCTAssertEqual(result, scoreResult(expectedScores[candidateIndex]!), scenario.id)
                guard case .score(let score) = result else { continue }
                if selected == nil || score < selected!.score {
                    selected = (candidateIndex, score)
                }
            }

            XCTAssertEqual(selected?.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selected?.score, scenario.expected.error, scenario.id)
            XCTAssertEqual(selected.map { palette[$0.index].hex }, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(
                tiedIndices(in: scenario.expected.scores, selectedScore: selected?.score),
                scenario.expected.tiedIndices,
                scenario.id
            )
            if let tieBroke = scenario.expected.tieBroke {
                XCTAssertEqual(scenario.expected.tiedIndices.count > 1, tieBroke, scenario.id)
            }
        }
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
    }

    private func paletteColor(_ vector: Vector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: channels(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func channels(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }

    private func scoreResult(_ score: ExpectedScore) -> ScorerResult {
        switch score {
        case .excluded: return .excluded
        case .value(let value): return .score(value)
        }
    }

    private func tiedIndices(in scores: [ExpectedCandidateScore], selectedScore: Double?) -> [Int] {
        guard let selectedScore else { return [] }
        return scores.compactMap { candidate in
            guard case .value(let score) = candidate.score, score == selectedScore else { return nil }
            return candidate.index
        }
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [Scenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer, selection, scenarios
    }
}

private struct Scenario: Decodable {
    let id: String
    let palette: [Vector]
    let target: Vector
    let weights: [String: Double]
    let expected: Expected
}

private struct Vector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?

    enum CodingKeys: String, CodingKey {
        case channels
        case hexColor = "hex_color"
        case index
    }
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
        case tieBroke = "tie_broke"
        case tiedIndices = "tied_indices"
    }
}

private struct ExpectedCandidateScore: Decodable {
    let index: Int
    let score: ExpectedScore
}

private enum ExpectedScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}
