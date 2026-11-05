import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedV1CorpusMatchesScoresAndSelectionsExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(channels: scenario.target.channels)
            let weights = ChannelWeights(channels: scenario.weights)
            let palette = scenario.palette.map(makePaletteColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(
                actualScores,
                scenario.expected.scores.map(\\.scorerResult),
                "score mismatch for corpus scenario \\(scenario.id)"
            )

            let selectedIndex = actualScores.enumerated().first { _, result in
                if case .score = result { return true }
                return false
            }.flatMap { firstEligible in
                actualScores.enumerated().reduce(firstEligible) { current, candidate in
                    guard case .score(let currentScore) = current.element,
                          case .score(let candidateScore) = candidate.element,
                          candidateScore < currentScore
                    else { return current }
                    return candidate
                }.offset
            }

            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, "selection mismatch for corpus scenario \\(scenario.id)")
            if let selectedIndex {
                XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor)
                XCTAssertEqual(actualScores[selectedIndex], .score(scenario.expected.error!))
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ entry: ParityVector) -> PaletteColor {
        let responses = entry.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { responses, channel in
            guard let condition = LightingCondition(rawValue: channel.key) else { return }
            responses[condition] = IlluminationResponse(brightness: channel.value)
        }
        return PaletteColor(
            id: entry.index ?? 0,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: responses
        )
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let missingPolicy: String
    let scenarios: [ParityScenario]

    enum CodingKeys: String, CodingKey {
        case algorithmVersion = "algorithm_version"
        case scorer, selection, scenarios
        case missingPolicy = "missing_policy"
    }
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

    enum CodingKeys: String, CodingKey {
        case index, channels
        case hexColor = "hex_color"
    }
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?

    enum CodingKeys: String, CodingKey {
        case error, scores
        case selectedHexColor = "selected_hex_color"
        case selectedIndex = "selected_index"
    }
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ScoreValue

    var scorerResult: ScorerResult {
        switch score {
        case .excluded: return .excluded
        case .value(let value): return .score(value)
        }
    }
}

private enum ScoreValue: Decodable {
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

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(channels.reduce(into: [LightingCondition: Double]()) { result, channel in
            guard let condition = LightingCondition(rawValue: channel.key) else { return }
            result[condition] = channel.value
        })
    }
}

private extension ChannelWeights {
    init(channels: [String: Double]) {
        self.init(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }
}
