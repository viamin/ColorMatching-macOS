import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCorpusMetadataPinsTheUpstreamAlgorithmContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertFalse(corpus.scenarios.isEmpty)
    }

    func testWeightedSquaredErrorMatchesEveryUpstreamParityScenario() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = channelWeights(from: scenario.weights)
            let palette = try scenario.palette.map(makeColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(scenario.palette.compactMap(\.index), Array(palette.indices), scenario.id)
            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (actual, expected) in zip(actualScores, scenario.expected.scores) {
                XCTAssertEqual(actual, expected.score.scorerResult, scenario.id)
            }

            var selected: (index: Int, score: Double)?
            for (index, result) in actualScores.enumerated() {
                guard case .score(let score) = result else { continue }
                if score < (selected?.score ?? .infinity) {
                    selected = (index, score)
                }
            }

            XCTAssertEqual(selected?.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selected.map { palette[$0.index].hex }, scenario.expected.selectedHexColor, scenario.id)
            XCTAssertEqual(selected?.score, scenario.expected.error, scenario.id)

            if scenario.expected.tieBroke == true {
                XCTAssertGreaterThan(scenario.expected.tiedIndices.count, 1, scenario.id)
                XCTAssertEqual(selected?.index, scenario.expected.tiedIndices.min(), scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        PaletteColor(
            id: try XCTUnwrap(candidate.index),
            hex: candidate.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: candidate.hexColor)),
            responses: responses(from: candidate.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
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
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityScoreValue
}

private enum ParityScoreValue: Decodable {
    case value(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
            return
        }
        guard try container.decode(String.self) == "excluded" else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
        self = .excluded
    }

    var scorerResult: ScorerResult {
        switch self {
        case .value(let score): .score(score)
        case .excluded: .excluded
        }
    }
}
