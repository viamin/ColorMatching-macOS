import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let palette = scenario.palette.map(makePaletteColor)
            let target = TargetResponseVector(channels: scenario.target.channels)
            let weights = makeWeights(scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            for expectedScore in scenario.expected.scores {
                switch (actualScores[expectedScore.index], expectedScore.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
                default:
                    XCTFail("\\(scenario.id): score at index \\(expectedScore.index) disagreed with corpus")
                }
            }

            let ranked = actualScores.enumerated().compactMap { index, result -> (Int, Double)? in
                guard case .score(let score) = result else { return nil }
                return (index, score)
            }
            let selected = ranked.min { $0.1 < $1.1 }
            XCTAssertEqual(selected?.0, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selected.map { palette[$0.0].hex }, scenario.expected.selectedHexColor, scenario.id)
            if let expectedError = scenario.expected.error {
                let actualError = try XCTUnwrap(selected?.1, scenario.id)
                XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertNil(selected, scenario.id)
            }

            let tied = ranked.filter { $0.1 == selected?.1 }.map(\\.0)
            XCTAssertEqual(tied, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(tied.count > 1, scenario.expected.tieBroke ?? false, scenario.id)
        }
    }

    private func loadCorpus() throws -> Corpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity/v1/corpus.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }

    private func makePaletteColor(_ vector: Vector) -> PaletteColor {
        let responses = vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                result[condition] = IlluminationResponse(brightness: entry.value)
            }
        }
        return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: RGBColor(hex: vector.hexColor)!, responses: responses)
    }

    private func makeWeights(_ values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }
}

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(channels.reduce(into: [LightingCondition: Double]()) { result, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                result[condition] = entry.value
            }
        })
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let selection: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let palette: [Vector]
    let target: Vector
    let weights: [String: Double]
    let expected: Expected
}

private struct Vector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
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
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a numeric score or excluded")
            }
            self = .excluded
        }
    }
}
