import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCommittedCorpusHasExpectedContractStamp() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorSelectionsMatchCommittedParityCorpusExactly() throws {
        let corpus = try loadCorpus()
        let scorer = WeightedSquaredErrorScorer()

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = scenario.palette.sorted { ($0.index ?? -1) < ($1.index ?? -1) }
            let results = palette
                .map { scorer.score(candidate: color(from: $0), target: target, weights: weights) }

            XCTAssertEqual(results, scenario.expected.scores.map(\\.scorerResult), scenario.id)

            let selection = selectEarliestScoredCandidate(from: results)
            XCTAssertEqual(selection?.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selection?.score, scenario.expected.error, scenario.id)
            XCTAssertEqual(selection.map { palette[$0.index].hexColor }, scenario.expected.selectedHexColor, scenario.id)

            let tiedIndices = results.enumerated().compactMap { index, result -> Int? in
                result == selection?.result ? index : nil
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(scenario.expected.tieBroke, tiedIndices.count > 1, scenario.id)
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SolverParityCorpus.self, from: data)
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
    }

    private func weights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }

    private func color(from vector: SolverParityCorpus.Vector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? 0,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: responses(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func selectEarliestScoredCandidate(from results: [ScorerResult]) -> (index: Int, score: Double, result: ScorerResult)? {
        results.enumerated().reduce(nil) { best, entry in
            guard case .score(let score) = entry.element else { return best }
            guard let best else { return (entry.offset, score, entry.element) }
            return score < best.score ? (entry.offset, score, entry.element) : best
        }
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
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    enum ExpectedScore: Decodable {
        case score(Double)
        case excluded

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let score = try? container.decode(Double.self) {
                self = .score(score)
            } else if try container.decode(String.self) == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
            }
        }

        var scorerResult: ScorerResult {
            switch self {
            case .score(let score): return .score(score)
            case .excluded: return .excluded
            }
        }
    }
}
