import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedV1Corpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(scenario.target.channels.lightingValues)
            let weights = ChannelWeights(channels: scenario.weights)
            let palette = try scenario.palette.map(PaletteColor.init)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores, scenario.expected.scores.map(\.scorerResult), scenario.id)
            XCTAssertEqual(selectEarliestLowestScore(actualScores), scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(scenario.expected.tiedIndices.first, scenario.expected.selectedIndex, scenario.id)

            if let expectedError = scenario.expected.error {
                let selection = try XCTUnwrap(selectEarliestLowestScore(actualScores), scenario.id)
                guard case .score(let actualError) = actualScores[selection] else {
                    return XCTFail("Selected candidate must be scoreable: \(scenario.id)")
                }
                XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertNil(selectEarliestLowestScore(actualScores), scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func selectEarliestLowestScore(_ scores: [ScorerResult]) -> Int? {
        var selection: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if selection == nil || score < selection!.score {
                selection = (index, score)
            }
        }
        return selection?.index
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let weights: [String: Double]
        let target: Vector
        let palette: [Vector]
        let expected: Expected
    }

    struct Vector: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [ExpectedScore]
        let selectedIndex: Int?
        let tiedIndices: [Int]
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: Score

        var scorerResult: ScorerResult {
            switch score {
            case .excluded: return .excluded
            case .value(let value): return .score(value)
            }
        }
    }

    enum Score: Decodable {
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
}

private extension Dictionary where Key == String, Value == Double {
    var lightingValues: [LightingCondition: Double] {
        compactMap { key, value in LightingCondition(rawValue: key).map { ($0, value) } }
            .reduce(into: [:]) { $0[$1.0] = $1.1 }
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

private extension PaletteColor {
    init(vector: SolverParityCorpus.Vector) throws {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw XCTestErrorWhileUnwrappingOptional()
        }
        self.init(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: rgb,
            responses: vector.channels.lightingValues.mapValues(IlluminationResponse.init(brightness:))
        )
    }

    init(_ vector: SolverParityCorpus.Vector) throws {
        try self.init(vector: vector)
    }
}

private struct XCTestErrorWhileUnwrappingOptional: Error {}
