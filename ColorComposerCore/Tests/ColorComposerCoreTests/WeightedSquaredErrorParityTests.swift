import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testMatchesColorMatchingV1ParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let weights = channelWeights(from: scenario.weights)
            let target = TargetResponseVector(channelValues(from: scenario.target.channels))
            let candidates = scenario.palette.map(makePaletteColor)
            let results = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(
                results,
                match: scenario.expected.scores,
                scenario: scenario.id
            )
            assertSelection(
                results,
                matches: scenario.expected,
                scenario: scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func channelWeights(from channels: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: channels["white"] ?? 0,
            red: channels["red"] ?? 0,
            green: channels["green"] ?? 0,
            blue: channels["blue"] ?? 0,
            lps: channels["lps"] ?? 0
        )
    }

    private func channelValues(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func makePaletteColor(_ vector: ParityVector) -> PaletteColor {
        PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: RGBColor(hex: vector.hexColor)!,
            responses: channelValues(from: vector.channels).mapValues { IlluminationResponse(brightness: $0) }
        )
    }

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [ParityExpectedScore],
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(scenario): score count", file: file, line: line)
        for expectedScore in expected {
            guard actual.indices.contains(expectedScore.index) else {
                return XCTFail("\(scenario): missing candidate \(expectedScore.index)", file: file, line: line)
            }
            switch (actual[expectedScore.index], expectedScore.score) {
            case (.excluded, .excluded):
                continue
            case (.score(let actualScore), .value(let expectedValue)):
                XCTAssertEqual(actualScore, expectedValue, accuracy: 1e-12, "\(scenario): candidate \(expectedScore.index)", file: file, line: line)
            default:
                XCTFail("\(scenario): candidate \(expectedScore.index) exclusion differs", file: file, line: line)
            }
        }
    }

    private func assertSelection(
        _ results: [ScorerResult],
        matches expected: ParityExpected,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selection = results.enumerated().reduce(nil as (index: Int, score: Double)?) { best, entry in
            guard case .score(let score) = entry.element else { return best }
            guard let best else { return (entry.offset, score) }
            return score < best.score ? (entry.offset, score) : best
        }

        XCTAssertEqual(selection?.index, expected.selectedIndex, "\(scenario): selected index", file: file, line: line)
        if let expectedError = expected.error, let selection {
            XCTAssertEqual(selection.score, expectedError, accuracy: 1e-12, "\(scenario): selected error", file: file, line: line)
        } else if expected.error != nil {
            XCTFail("\(scenario): expected a selected score", file: file, line: line)
        } else {
            XCTAssertNil(selection, "\(scenario): expected no selection", file: file, line: line)
        }

        if expected.tieBroke == true {
            XCTAssertEqual(selection?.index, expected.tiedIndices.min(), "\(scenario): earliest tied candidate must win", file: file, line: line)
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
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
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityExpectedScore]
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityExpectedScore: Decodable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable {
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
