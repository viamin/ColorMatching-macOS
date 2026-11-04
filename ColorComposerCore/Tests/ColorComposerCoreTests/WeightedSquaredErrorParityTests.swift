import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(channels(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let palette = scenario.palette.map(makePaletteColor)
            let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(
                scenario.palette.map(\.index),
                Array(scenario.palette.indices),
                "Corpus palette indices must match their selection order for \(scenario.id)"
            )
            XCTAssertEqual(results.count, scenario.expected.scores.count, scenario.id)

            for (actual, expected) in zip(results, scenario.expected.scores) {
                assert(actual, matches: expected.score, scenarioID: scenario.id, candidateIndex: expected.index)
            }

            let scored = results.enumerated().compactMap { index, result -> (Int, Double)? in
                guard case .score(let score) = result else { return nil }
                return (index, score)
            }
            let bestScore = scored.map(\.1).min()
            let tiedIndices = bestScore.map { score in
                scored.compactMap { $0.1 == score ? $0.0 : nil }
            } ?? []
            let selectedIndex = tiedIndices.first

            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, "selection mismatch for \(scenario.id)")
            XCTAssertEqual(bestScore, scenario.expected.error, "error mismatch for \(scenario.id)")
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, "tie mismatch for \(scenario.id)")
            XCTAssertEqual(
                bestScore.map { _ in tiedIndices.count > 1 },
                scenario.expected.tieBroke,
                "tie-break flag mismatch for \(scenario.id)"
            )
            XCTAssertEqual(
                selectedIndex.map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                "selected color mismatch for \(scenario.id)"
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: file))
    }

    private func makePaletteColor(_ fixture: ParityPaletteColor) -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: channels(from: fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func channels(from values: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: values.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
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

    private func assert(
        _ actual: ScorerResult,
        matches expected: ExpectedScore,
        scenarioID: String,
        candidateIndex: Int
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            return
        case (.score(let actualScore), .value(let expectedScore)):
            XCTAssertEqual(actualScore, expectedScore, "score mismatch for \(scenarioID) candidate \(candidateIndex)")
        default:
            XCTFail("exclusion mismatch for \(scenarioID) candidate \(candidateIndex)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityPaletteColor]
    let target: ParityVector
    let weights: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityCandidateScore: Decodable {
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
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a numeric score or excluded")
            }
            self = .excluded
        }
    }
}

private struct ParityPaletteColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}
