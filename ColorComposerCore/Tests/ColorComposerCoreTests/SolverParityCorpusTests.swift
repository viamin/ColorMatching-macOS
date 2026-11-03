import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesVersionOneCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        for scenario in corpus.scenarios {
            let palette = try scenario.palette.map(makePaletteColor)
            let target = try makeTarget(scenario.target.channels)
            let weights = makeWeights(scenario.weights)
            let results = palette.map { WeightedSquaredErrorScorer().score(candidate: $0, target: target, weights: weights) }

            for (actual, expected) in zip(results, scenario.expected.scores) {
                switch (actual, expected.score) {
                case (.excluded, .excluded):
                    break
                case (.score(let actual), .value(let expected)):
                    XCTAssertEqual(actual, expected, accuracy: 1e-12, scenario.id)
                default:
                    XCTFail("\(scenario.id): candidate \(expected.index) did not match exclusion policy")
                }
            }

            let selection = results.enumerated().compactMap { index, result -> (Int, Double)? in
                guard case .score(let error) = result else { return nil }
                return (index, error)
            }.min { $0.1 < $1.1 }
            XCTAssertEqual(selection?.0, scenario.expected.selectedIndex, scenario.id)
            if let expectedError = scenario.expected.error {
                XCTAssertEqual(selection?.1, expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertNil(selection, scenario.id)
            }
            if let index = selection?.0 {
                XCTAssertEqual(palette[index].hex, scenario.expected.selectedHexColor, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ParityCorpus/v1/corpus.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ candidate: ParityCandidate) throws -> PaletteColor {
        let responses = try candidate.channels.reduce(into: [LightingCondition: IlluminationResponse]()) {
            responses, entry in
            responses[try condition(named: entry.key)] = IlluminationResponse(brightness: entry.value)
        }
        return PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: candidate.hexColor)),
            responses: responses
        )
    }

    private func makeTarget(_ channels: [String: Double]) throws -> TargetResponseVector {
        TargetResponseVector(try channels.reduce(into: [:]) { target, entry in
            target[try condition(named: entry.key)] = entry.value
        })
        }
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights["white"] ?? 0,
            red: weights["red"] ?? 0,
            green: weights["green"] ?? 0,
            blue: weights["blue"] ?? 0,
            lps: weights["lps"] ?? 0
        )
    }

    private func condition(named name: String) throws -> LightingCondition {
        try XCTUnwrap(LightingCondition(rawValue: name), "Unknown corpus channel: \(name)")
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityTarget
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct ParityTarget: Decodable {
    let channels: [String: Double]
}

private struct ParityExpectation: Decodable {
    let error: Double?
    let selectedHexColor: String?
    let selectedIndex: Int?
    let scores: [ParityScore]
}

private struct ParityScore: Decodable {
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
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown score")
        }
    }
}
