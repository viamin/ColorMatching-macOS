import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesCommittedColorMatchingParityCorpus() throws {
        let corpus = try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = makeWeights(scenario.weights)
            let palette = scenario.palette.map(makeColor)
            let results = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(results.count, scenario.expected.scores.count, scenario.id)
            for ((candidate, result), expected) in zip(zip(scenario.palette, results), scenario.expected.scores) {
                XCTAssertEqual(candidate.index, expected.index, scenario.id)
                assert(result, matches: expected.score, scenarioID: scenario.id, index: expected.index)
            }

            let selectedIndex = selectedIndex(from: results)
            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
            if let selectedIndex {
                XCTAssertEqual(palette[selectedIndex].hex, scenario.expected.selectedHexColor, scenario.id)
                guard case .score(let score) = results[selectedIndex] else {
                    return XCTFail("Selected candidate must be scored: \(scenario.id)")
                }
                let expectedError = try XCTUnwrap(scenario.expected.error, "Selected candidate must have an expected error")
                XCTAssertEqual(score, expectedError, accuracy: 1e-12, scenario.id)
            } else {
                XCTAssertNil(scenario.expected.error, scenario.id)
            }

            let tiedIndices = tiedIndices(in: results)
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            XCTAssertEqual(tiedIndices.count > 1, scenario.expected.tieBroke ?? false, scenario.id)
        }
    }

    private var corpusURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
    }

    private func makeColor(_ fixture: ParityPaletteColor) -> PaletteColor {
        PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: RGBColor(hex: fixture.hexColor)!,
            responses: responses(from: fixture.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            condition(named: name).map { ($0, value) }
        })
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

    private func condition(named name: String) -> LightingCondition? {
        switch name {
        case "white": .white
        case "red": .red
        case "green": .green
        case "blue": .blue
        case "lps": .lps
        default: nil
        }
    }

    private func selectedIndex(from results: [ScorerResult]) -> Int? {
        results.enumerated().reduce(into: (index: Int?.none, score: Double.infinity)) { best, candidate in
            guard case .score(let score) = candidate.element, score < best.score else { return }
            best = (candidate.offset, score)
        }.index
    }

    private func tiedIndices(in results: [ScorerResult]) -> [Int] {
        guard let selectedIndex = selectedIndex(from: results), case .score(let bestScore) = results[selectedIndex] else {
            return []
        }
        return results.enumerated().compactMap { index, result in
            guard case .score(let score) = result, score == bestScore else { return nil }
            return index
        }
    }

    private func assert(_ result: ScorerResult, matches expected: ParityScore, scenarioID: String, index: Int) {
        switch (result, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, accuracy: 1e-12, "\(scenarioID), candidate \(index)")
        default:
            XCTFail("\(scenarioID), candidate \(index): expected \(expected), received \(result)")
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
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
    let index: Int
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityTarget: Decodable {
    let channels: [String: Double]
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
    let score: ParityScore
}

private enum ParityScore: Decodable, CustomStringConvertible {
    case excluded
    case score(Double)

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

    var description: String {
        switch self {
        case .excluded: "excluded"
        case .score(let value): "score(\(value))"
        }
    }
}
