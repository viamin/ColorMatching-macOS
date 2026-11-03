import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedV1ParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.scenarios.count, 12)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(for: scenario.target.channels))
            let weights = channelWeights(from: scenario.weights)
            let palette = try scenario.palette.map(paletteColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (index, pair) in zip(actualScores, scenario.expected.scores).enumerated() {
                let (actual, expected) = pair
                XCTAssertEqual(expected.index, index, "\(scenario.id): corpus ordering changed")
                assert(actual, matches: expected.score, scenarioID: scenario.id)
            }

            let selection = selectedIndex(for: actualScores)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selection.tiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(selection.index.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(try XCTUnwrap(selection.error), expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertNil(selection.error, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixture = testFile.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func paletteColor(_ vector: ParityVector) throws -> PaletteColor {
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor))
        return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: rgb, responses: responses(for: vector.channels))
    }

    private func responses(for channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
    }

    private func channelWeights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func selectedIndex(for scores: [ScorerResult]) -> (index: Int?, error: Double?, tiedIndices: [Int]) {
        let rankable = scores.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        guard let minimum = rankable.map(\.1).min() else { return (nil, nil, []) }
        let ties = rankable.filter { $0.1 == minimum }.map(\.0)
        return (ties.first, minimum, ties)
    }

    private func assert(_ actual: ScorerResult, matches expected: ParityScore, scenarioID: String) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, scenarioID)
        default:
            XCTFail("\(scenarioID): expected \(expected), got \(actual)")
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
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
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

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return String(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}
