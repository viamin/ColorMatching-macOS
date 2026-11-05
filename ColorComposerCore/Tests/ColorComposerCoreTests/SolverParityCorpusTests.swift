import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(channels(from: scenario.target.channels))
            let palette = scenario.palette.map(makeColor)
            let scorer = WeightedSquaredErrorScorer()

            for expectedScore in scenario.expected.scores {
                let actual = scorer.score(
                    candidate: palette[expectedScore.index], target: target, weights: weights
                )
                assert(actual, matches: expectedScore.score, scenario: scenario.id)
            }

            let selection = select(palette: palette, target: target, weights: weights, scorer: scorer)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selection.error, scenario.expected.error ?? .infinity, accuracy: 1e-12, scenario.id)
            XCTAssertEqual(
                selection.index.map { palette[$0].hex },
                scenario.expected.selectedHexColor,
                scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent().appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
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

    private func makeColor(_ vector: ParityVector) -> PaletteColor {
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

    private func select(
        palette: [PaletteColor],
        target: TargetResponseVector,
        weights: ChannelWeights,
        scorer: WeightedSquaredErrorScorer
    ) -> (index: Int?, error: Double) {
        var bestIndex: Int?
        var bestError = Double.infinity

        for (index, candidate) in palette.enumerated() {
            guard case .score(let error) = scorer.score(candidate: candidate, target: target, weights: weights),
                  error < bestError
            else { continue }
            bestIndex = index
            bestError = error
        }
        return (bestIndex, bestError)
    }

    private func assert(_ result: ScorerResult, matches expected: ParityScore, scenario: String) {
        switch (result, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario)
        default:
            XCTFail("\(scenario): expected \(expected), got \(result)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: ParityVector
    let palette: [ParityVector]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityCandidateScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
}

private struct ParityCandidateScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }
}
