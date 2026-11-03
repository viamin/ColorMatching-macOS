import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityCorpusTests: XCTestCase {
    func testCommittedCorpusReplaysExactly() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })

        for scenario in corpus.scenarios {
            try assertScenario(scenario)
        }
    }

    private func assertScenario(_ scenario: ParityCorpus.Scenario) throws {
        let scorer = WeightedSquaredErrorScorer()
        let palette = try scenario.palette
            .sorted { ($0.index ?? .max) < ($1.index ?? .max) }
            .map(makePaletteColor)
        let target = makeTarget(scenario.target)
        let weights = makeWeights(scenario.weights)
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        XCTAssertEqual(scenario.expected.scores.map(\.index).sorted(), Array(palette.indices), scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores.sorted { $0.index < $1.index }) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, scenario.id)
            default:
                XCTFail("\(scenario.id): score did not match corpus", file: #filePath, line: #line)
            }
        }

        guard let expectedError = scenario.expected.error else {
            XCTAssertNil(scenario.expected.selectedIndex, scenario.id)
            XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            XCTAssertEqual(scenario.expected.tiedIndices, [], scenario.id)
            XCTAssertFalse(actualScores.contains { if case .score = $0 { return true }; return false }, scenario.id)
            return
        }

        let winningIndices = actualScores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == expectedError else { return nil }
            return index
        }
        XCTAssertEqual(winningIndices, scenario.expected.tiedIndices, scenario.id)
        XCTAssertEqual(try XCTUnwrap(scenario.expected.tieBroke, scenario.id), winningIndices.count > 1, scenario.id)

        let selectedIndex = try XCTUnwrap(winningIndices.first, scenario.id)
        XCTAssertEqual(selectedIndex, try XCTUnwrap(scenario.expected.selectedIndex, scenario.id), scenario.id)
        XCTAssertEqual(palette[selectedIndex].hex, try XCTUnwrap(scenario.expected.selectedHexColor, scenario.id), scenario.id)
    }

    private func makePaletteColor(_ vector: ParityCorpus.Vector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw CorpusError.invalidHex(vector.hexColor)
        }
        let responses = vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { responses, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                responses[condition] = IlluminationResponse(brightness: entry.value)
            }
        }
        return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private func makeTarget(_ vector: ParityCorpus.Vector) -> TargetResponseVector {
        TargetResponseVector(vector.channels.reduce(into: [LightingCondition: Double]()) { responses, entry in
            if let condition = LightingCondition(rawValue: entry.key) {
                responses[condition] = entry.value
            }
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

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixtureURL = testDirectory.appendingPathComponent("Fixtures/WeightedSquaredErrorParityCorpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }
}

private enum CorpusError: Error {
    case invalidHex(String)
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let scorer: String
    let selection: String
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [Scenario]

    struct Scenario: Decodable {
        let id: String
        let palette: [Vector]
        let target: Vector
        let weights: [String: Double]
        let expected: Expected
    }

    struct Vector: Decodable {
        let index: Int?
        let hexColor: String
        let channels: [String: Double]
    }

    struct Expected: Decodable {
        let error: Double?
        let scores: [ExpectedScore]
        let selectedHexColor: String?
        let selectedIndex: Int?
        let tieBroke: Bool?
        let tiedIndices: [Int]
    }

    struct ExpectedScore: Decodable {
        let index: Int
        let score: Score
    }

    enum Score: Decodable {
        case excluded
        case value(Double)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Double.self) {
                self = .value(value)
            } else if try container.decode(String.self) == "excluded" {
                self = .excluded
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number or excluded")
            }
        }
    }
}
