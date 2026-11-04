import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responseVector(from: scenario.target.channels))
            let weights = channelWeights(from: scenario.weights)
            let palette = scenario.palette.map(paletteColor(from:))
            let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(
                results.map(fixtureScore(from:)),
                scenario.expected.scores.sorted { $0.index < $1.index }.map(\.score),
                "candidate scores diverged for \\(scenario.id)"
            )

            let selectedIndex = results.enumerated().compactMap { index, result -> Int? in
                guard case .score = result else { return nil }
                return index
            }.min { left, right in
                numericScore(from: results[left])! < numericScore(from: results[right])!
            }

            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, "selection diverged for \\(scenario.id)")
            XCTAssertEqual(selectedIndex.map { palette[$0].hex }, scenario.expected.selectedHexColor)
            XCTAssertEqual(selectedIndex.map { numericScore(from: results[$0])! }, scenario.expected.error)
            XCTAssertEqual(
                scenario.expected.tieBroke,
                scenario.expected.tiedIndices.count > 1 ? true : (selectedIndex == nil ? nil : false),
                "tie-breaking evidence diverged for \\(scenario.id)"
            )
            XCTAssertEqual(
                selectedIndex.map { index in
                    results.enumerated().compactMap { candidateIndex, result in
                        numericScore(from: result) == numericScore(from: results[index]) ? candidateIndex : nil
                    }
                } ?? [],
                scenario.expected.tiedIndices,
                "tie candidates diverged for \\(scenario.id)"
            )
        }
    }

    private let scorer = WeightedSquaredErrorScorer()

    private func loadCorpus() throws -> SolverParityCorpus {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = directory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: url))
    }

    private func paletteColor(from fixture: SolverParityCorpus.PaletteColor) -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: responseVector(from: fixture.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responseVector(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func channelWeights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white", default: 0],
            red: channels["red", default: 0],
            green: channels["green", default: 0],
            blue: channels["blue", default: 0],
            lps: channels["lps", default: 0]
        )
    }

    private func fixtureScore(from result: ScorerResult) -> SolverParityCorpus.Score {
        switch result {
        case .score(let value): return .value(value)
        case .excluded: return .excluded
        }
    }

    private func numericScore(from result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let palette: [PaletteColor]
        let target: Target
        let weights: [String: Double]
        let expected: Expected
    }

    struct PaletteColor: Decodable {
        let index: Int
        let hexColor: String
        let channels: [String: Double]
    }

    struct Target: Decodable {
        let channels: [String: Double]
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [IndexedScore]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct IndexedScore: Decodable {
        let index: Int
        let score: Score
    }

    enum Score: Equatable, Decodable {
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
