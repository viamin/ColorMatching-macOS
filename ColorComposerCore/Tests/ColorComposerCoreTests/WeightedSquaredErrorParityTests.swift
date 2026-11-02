import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedV1CorpusReplaysExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityScenario) throws {
        let weights = ChannelWeights(channels: scenario.weights)
        let target = TargetResponseVector(channels: scenario.target.channels)
        let palette = try scenario.palette
            .sorted { $0.index < $1.index }
            .map { try PaletteColor($0) }
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(palette.map(\.id), scenario.palette.sorted { $0.index < $1.index }.map(\.index))
        XCTAssertEqual(actualScores.count, scenario.expected.scores.count)
        for (actual, expected) in zip(actualScores, scenario.expected.scores) {
            XCTAssertEqual(actual, expected.scorerResult, "candidate index \(expected.index)")
        }

        let selectedIndex = earliestSelection(in: actualScores)

        XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex)
        XCTAssertEqual(selectedIndex.map { palette[$0].hex }, scenario.expected.selectedHexColor)

        let selectedScore = selectedIndex.flatMap { index -> Double? in
            guard case .score(let score) = actualScores[index] else { return nil }
            return score
        }
        XCTAssertEqual(selectedScore, scenario.expected.error)

        let tiedIndices = selectedScore.map { score in
            actualScores.enumerated().compactMap { index, result in
                result == .score(score) ? index : nil
            }
        } ?? []
        XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices)
        XCTAssertEqual(scenario.expected.tieBroke, selectedScore.map { _ in tiedIndices.count > 1 })
    }

    private func earliestSelection(in scores: [ScorerResult]) -> Int? {
        var selection: (index: Int, score: Double)?
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result else { continue }
            if let selection {
                if score < selection.score {
                    selection = (index, score)
                }
            } else {
                selection = (index, score)
            }
        }
        return selection?.index
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let scenarios: [ParityScenario]
    let scorer: String
    let selection: String
}

private struct ParityScenario: Decodable {
    let expected: ParityExpectation
    let id: String
    let palette: [ParityColor]
    let target: ParityColor
    let weights: [String: Double]
}

private struct ParityExpectation: Decodable {
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

    var scorerResult: ScorerResult {
        switch score {
        case .excluded:
            return .excluded
        case .score(let value):
            return .score(value)
        }
    }
}

private enum ParityScoreValue: Decodable {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .score(value)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
    }
}

private struct ParityColor: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
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

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(Dictionary(uniqueKeysWithValues: channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, brightness) }
        }))
    }
}

private extension PaletteColor {
    init(_ fixture: ParityColor) throws {
        guard let rgb = RGBColor(hex: fixture.hexColor) else {
            throw FixtureError.invalidHex(fixture.hexColor)
        }
        let responses = Dictionary(uniqueKeysWithValues: fixture.channels.compactMap { name, brightness in
            LightingCondition(rawValue: name).map { ($0, IlluminationResponse(brightness: brightness)) }
        })
        self.init(id: fixture.index ?? -1, hex: fixture.hexColor, rgb: rgb, responses: responses)
    }
}

private enum FixtureError: Error {
    case invalidHex(String)
}
