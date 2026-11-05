import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedServerParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = makeWeights(scenario.weights)
            let target = TargetResponseVector(makeResponses(scenario.target.channels))
            let palette = try scenario.palette.map(makeColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores, scenario.expected.scores.map(makeExpectedScore), scenario.id)

            let best = actualScores.enumerated().compactMap { index, score -> (Int, Double)? in
                guard case .score(let value) = score else { return nil }
                return (index, value)
            }.min { $0.1 < $1.1 }

            XCTAssertEqual(best?.0, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(best?.1, scenario.expected.error, scenario.id)
            XCTAssertEqual(best.map { palette[$0.0].hex }, scenario.expected.selectedHexColor, scenario.id)
            let actualTiedIndices = actualScores.enumerated().compactMap { index, score -> Int? in
                guard case .score(let value) = score, let best else { return nil }
                return value == best.1 ? index : nil
            }
            XCTAssertEqual(actualTiedIndices, scenario.expected.tiedIndices, scenario.id)

            let expectedTieBreak: Bool? = scenario.expected.selectedIndex.map { _ in scenario.expected.tiedIndices.count > 1 }
            XCTAssertEqual(scenario.expected.tieBroke, expectedTieBreak, scenario.id)

            if weights.activeEntries.allSatisfy({ scenario.target.channels[$0.condition.rawValue] != nil }) {
                let sourceGrids = Dictionary(uniqueKeysWithValues: weights.activeEntries.map { condition, _ in
                    (condition, BrightnessGrid(width: 1, height: 1, values: [scenario.target.channels[condition.rawValue]!]))
                })
                let result = try CompositionSolver().solve(palette: palette, sourceGrids: sourceGrids, weights: weights)
                XCTAssertEqual(result.colorIndex(x: 0, y: 0), scenario.expected.selectedIndex, scenario.id)
                XCTAssertEqual(result.error(x: 0, y: 0), scenario.expected.error, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makeColor(_ entry: ParityEntry) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: entry.hexColor) else {
            throw ParityFixtureError.invalidHex(entry.hexColor)
        }
        return PaletteColor(id: entry.index ?? -1, hex: entry.hexColor, rgb: rgb, responses: makeResponses(entry.channels))
    }

    private func makeResponses(_ channels: [String: Double]) -> [LightingCondition: IlluminationResponse] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, IlluminationResponse(brightness: value)) }
        })
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

    private func makeExpectedScore(_ score: ParityExpectedScore) -> ScorerResult {
        switch score.score {
        case .number(let value): return .score(value)
        case .excluded: return .excluded
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
    let target: ParityEntry
    let palette: [ParityEntry]
    let expected: ParityExpected
}

private struct ParityEntry: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let scores: [ParityExpectedScore]
    let selectedIndex: Int?
    let selectedHexColor: String?
    let error: Double?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
    case number(Double)
    case excluded

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a score or excluded")
        }
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
}
