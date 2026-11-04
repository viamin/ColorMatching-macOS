import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testReplaysCommittedV1CorpusExactly() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = ChannelWeights(channels: scenario.weights)
            let target = TargetResponseVector(channels: scenario.target.channels)
            let palette = scenario.palette.map(makePaletteColor)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(actualScores, equal: scenario.expected.scores, scenario: scenario.id)
            assertSelection(
                palette: palette,
                scores: actualScores,
                expected: scenario.expected,
                scenario: scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: vector.channels.reduce(into: [:]) { responses, channel in
                responses[LightingCondition(parityName: channel.key)] = IlluminationResponse(brightness: channel.value)
            }
        )
    }

    private func assertScores(
        _ actual: [ScorerResult],
        equal expected: [ParityExpectedScore],
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(scenario): score count", file: file, line: line)
        for (actualScore, expectedScore) in zip(actual, expected.sorted { $0.index < $1.index }) {
            switch (actualScore, expectedScore.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actualValue), .number(let expectedValue)):
                XCTAssertEqual(actualValue, expectedValue, "\(scenario): candidate \(expectedScore.index)", file: file, line: line)
            default:
                XCTFail("\(scenario): candidate \(expectedScore.index) exclusion mismatch", file: file, line: line)
            }
        }
    }

    private func assertSelection(
        palette: [PaletteColor],
        scores: [ScorerResult],
        expected: ParityExpected,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bestScore = scores.compactMap { result -> Double? in
            guard case .score(let value) = result else { return nil }
            return value
        }.min()
        let tiedIndices = scores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let value) = result, value == bestScore else { return nil }
            return index
        }
        let tieBroke = bestScore.map { _ in tiedIndices.count > 1 }

        XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenario): tied indices", file: file, line: line)
        XCTAssertEqual(expected.tieBroke, tieBroke, "\(scenario): tie evidence", file: file, line: line)

        guard let selectedIndex = expected.selectedIndex else {
            XCTAssertNil(bestScore, "\(scenario): expected no selected candidate", file: file, line: line)
            return
        }

        XCTAssertEqual(tiedIndices.first, selectedIndex, "\(scenario): earliest tied candidate must win", file: file, line: line)
        XCTAssertEqual(palette[selectedIndex].hex, expected.selectedHexColor, "\(scenario): selected color", file: file, line: line)
        XCTAssertEqual(bestScore, expected.error, "\(scenario): selected error", file: file, line: line)
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
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected score or excluded")
        }
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

private extension TargetResponseVector {
    init(channels: [String: Double]) {
        self.init(channels.reduce(into: [:]) { target, channel in
            target[LightingCondition(parityName: channel.key)] = channel.value
        })
    }
}

private extension LightingCondition {
    init(parityName: String) {
        switch parityName {
        case "white": self = .white
        case "red": self = .red
        case "green": self = .green
        case "blue": self = .blue
        case "lps": self = .lps
        default: preconditionFailure("Unexpected parity light source: \(parityName)")
        }
    }
}
