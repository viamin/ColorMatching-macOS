import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysCommittedV1ParityCorpusExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let weights = weights(from: scenario.weights)
        let target = target(from: scenario.target.channels)
        let palette = try scenario.palette.map(makeColor)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        for expectedScore in scenario.expected.scores {
            XCTAssertEqual(
                actualScores[expectedScore.index],
                expectedScore.result,
                "\(scenario.id): candidate \(expectedScore.index)"
            )
        }

        let selectedIndex = selectedIndex(from: actualScores)
        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(
            selectedIndex.map { palette[$0].hex },
            scenario.expected.selectedHexColor,
            scenario.id
        )
        XCTAssertEqual(
            selectedIndex.flatMap { scoreValue(actualScores[$0]) },
            scenario.expected.error,
            scenario.id
        )

        let tiedIndices = tiedIndices(in: actualScores, at: scenario.expected.error)
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        let tieBroke = selectedIndex.map { _ in tiedIndices.count > 1 }
        XCTAssertEqual(scenario.expected.tieBroke, tieBroke, scenario.id)
    }

    private func selectedIndex(from scores: [ScorerResult]) -> Int? {
        var selection: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result,
                  selection == nil || score < selection!.score else { continue }
            selection = (index, score)
        }
        return selection?.index
    }

    private func tiedIndices(in scores: [ScorerResult], at error: Double?) -> [Int] {
        guard let error else { return [] }
        return scores.enumerated().compactMap { index, result in
            scoreValue(result) == error ? index : nil
        }
    }

    private func scoreValue(_ result: ScorerResult) -> Double? {
        guard case .score(let value) = result else { return nil }
        return value
    }

    private func weights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }

    private func target(from channels: [String: Double]) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        }))
    }

    private func makeColor(_ entry: ParityPaletteEntry) throws -> PaletteColor {
        let responses = Dictionary(uniqueKeysWithValues: entry.channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
        return PaletteColor(
            id: entry.index,
            hex: entry.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: entry.hexColor)),
            responses: responses
        )
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let corpusURL = testDirectory.appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: corpusURL))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpected
    let id: String
    let palette: [ParityPaletteEntry]
    let target: ParityVector
    let weights: [String: Double]
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

    var result: ScorerResult {
        switch score {
        case .excluded: .excluded
        case .value(let value): .score(value)
        }
    }
}

private enum ParityScoreValue: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a score or the excluded sentinel."
                )
            }
            self = .excluded
        }
    }
}

private struct ParityPaletteEntry: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}
