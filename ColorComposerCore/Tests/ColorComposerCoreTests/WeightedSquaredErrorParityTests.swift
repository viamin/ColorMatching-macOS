import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesVersionOneColorMatchingParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let palette = scenario.palette.map(paletteColor)
            let expectedScores = Dictionary(uniqueKeysWithValues: scenario.expected.scores.map { ($0.index, $0.score) })
            var selectedIndex: Int?
            var selectedScore: Double?

            for (index, candidate) in palette.enumerated() {
                let result = scorer.score(candidate: candidate, target: target, weights: weights(from: scenario.weights))
                assert(result, equals: expectedScores[index]!, scenarioID: scenario.id, candidateIndex: index)
                if case .score(let score) = result, selectedScore == nil || score < selectedScore! {
                    selectedIndex = index
                    selectedScore = score
                }
            }

            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selectedScore, scenario.expected.error, scenario.id)
            XCTAssertEqual(selectedIndex.flatMap { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(
                scenario.expected.tiedIndices,
                scenario.expected.scores.compactMap { score in
                    score.score.numericValue == scenario.expected.error ? score.index : nil
                },
                scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let corpusURL = testDirectory
            .appendingPathComponent("Fixtures/WeightedSquaredError/v1", isDirectory: true)
            .appendingPathComponent("corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }

    private func paletteColor(_ fixture: ParityPaletteColor) -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: responses(from: fixture.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        })
    }

    private func weights(from fixture: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: fixture["white", default: 0],
            red: fixture["red", default: 0],
            green: fixture["green", default: 0],
            blue: fixture["blue", default: 0],
            lps: fixture["lps", default: 0]
        )
    }

    private func assert(
        _ result: ScorerResult,
        equals expected: ParityScore,
        scenarioID: String,
        candidateIndex: Int
    ) {
        switch (result, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .value(let value)):
            XCTAssertEqual(actual, value, "\(scenarioID), candidate \(candidateIndex)")
        default:
            XCTFail("\(scenarioID), candidate \(candidateIndex): expected \(expected), got \(result)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityPaletteColor]
    let target: ParityTarget
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityPaletteColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct ParityTarget: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case excluded
    case value(Double)

    var numericValue: Double? {
        guard case .value(let value) = self else { return nil }
        return value
    }

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
