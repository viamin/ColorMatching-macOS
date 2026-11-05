import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCommittedParityCorpusHasExpectedContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.allCases.map(\.rawValue))
        XCTAssertFalse(corpus.scenarios.isEmpty)
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerReplaysCommittedParityCorpusExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let target = target(from: scenario.target)
            let palette = try scenario.palette.sorted { ($0.index ?? .max) < ($1.index ?? .max) }.map(color(from:))
            let weights = ChannelWeights(values: scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(scenario.expected.scores.map(\.index), Array(palette.indices), scenario.id)
            XCTAssertEqual(actualScores, scenario.expected.scores.map { ScorerResult($0.score) }, scenario.id)

            let selection = selectedIndex(from: actualScores)
            XCTAssertEqual(selection.index, scenario.expected.selectedIndex, scenario.id)
            XCTAssertEqual(selection.error, scenario.expected.error, scenario.id)

            let tiedIndices = actualScores.enumerated().compactMap { index, result -> Int? in
                guard case .score(let score) = result, score == selection.error else { return nil }
                return index
            }
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
            let tieBroke = selection.index.map { _ in tiedIndices.count > 1 }
            XCTAssertEqual(scenario.expected.tieBroke, tieBroke, scenario.id)

            if let index = selection.index {
                XCTAssertEqual(palette[index].hex, scenario.expected.selectedHexColor, scenario.id)
            }
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/weighted_squared_error_v1.json")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ParityCorpus.self, from: Data(contentsOf: fixtureURL))
    }

    private func color(from vector: ParityVector) throws -> PaletteColor {
        let responses = try Dictionary(uniqueKeysWithValues: vector.channels.compactMap { name, brightness in
            guard let condition = LightingCondition(rawValue: name) else { return nil }
            return (condition, IlluminationResponse(brightness: brightness))
        })
        return PaletteColor(
            id: try XCTUnwrap(vector.index),
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func target(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(Dictionary(uniqueKeysWithValues: vector.channels.compactMap { name, brightness in
            guard let condition = LightingCondition(rawValue: name) else { return nil }
            return (condition, brightness)
        }))
    }

    private func selectedIndex(from scores: [ScorerResult]) -> (index: Int?, error: Double?) {
        var selection: (index: Int?, error: Double?) = (nil, nil)
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result, selection.error == nil || score < selection.error! else { continue }
            selection = (index, score)
        }
        return selection
    }
}

private extension ChannelWeights {
    init(values: [String: Double]) {
        self.init(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }
}

private extension ScorerResult {
    init(_ score: ParityScore) {
        switch score {
        case .excluded:
            self = .excluded
        case .score(let value):
            self = .score(value)
        }
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
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
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
    case excluded
    case score(Double)

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

