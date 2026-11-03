import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testWeightedSquaredErrorMatchesCommittedParityCorpus() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")

        for scenario in corpus.scenarios {
            try assertParity(for: scenario)
        }
    }

    private func assertParity(for scenario: ParityScenario) throws {
        let palette = try scenario.palette.map(makePaletteColor)
        let target = TargetResponseVector(responseVector(from: scenario.target.channels))
        let weights = makeWeights(from: scenario.weights)
        let scorer = WeightedSquaredErrorScorer()
        let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

        XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
        XCTAssertEqual(scenario.palette.map(\.index), Array(palette.indices), scenario.id)
        for (actual, expected) in zip(actualScores, scenario.expected.scores) {
            switch (actual, expected.score) {
            case (.excluded, .excluded):
                break
            case (.score(let value), .value(let expectedValue)):
                XCTAssertEqual(value, expectedValue, accuracy: 1e-12, scenario.id)
            default:
                XCTFail("\(scenario.id): score for candidate \(expected.index) differs from corpus")
            }
        }

        let selection = selectedIndex(from: actualScores)
        XCTAssertEqual(selection, scenario.expected.selectedIndex, scenario.id)
        XCTAssertEqual(selection.map { palette[$0].hex }, scenario.expected.selectedHexColor, scenario.id)

        if let expectedError = scenario.expected.error {
            let actualError = try XCTUnwrap(selection.flatMap { actualScores[$0].value }, scenario.id)
            XCTAssertEqual(actualError, expectedError, accuracy: 1e-12, scenario.id)
        } else {
            XCTAssertNil(selection, scenario.id)
        }

        if scenario.expected.tieBroke == true {
            XCTAssertEqual(selection, scenario.expected.tiedIndices.min(), scenario.id)
        }
    }

    private func selectedIndex(from scores: [ScorerResult]) -> Int? {
        var winner: Int?
        var best = Double.infinity
        for (index, score) in scores.enumerated() {
            guard case .score(let value) = score, value < best else { continue }
            best = value
            winner = index
        }
        return winner
    }

    private func makePaletteColor(_ fixture: ParityCandidate) throws -> PaletteColor {
        let responses = responseVector(from: fixture.channels).mapValues(IlluminationResponse.init)
        return PaletteColor(
            id: fixture.index,
            hex: fixture.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: fixture.hexColor)),
            responses: responses
        )
    }

    private func responseVector(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { name, value in
            LightingCondition(rawValue: name).map { ($0, value) }
        })
    }

    private func makeWeights(from weights: [String: Double]) -> ChannelWeights {
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
        let url = testDirectory.appendingPathComponent("Resources/Parity/corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }
}

private extension ScorerResult {
    var value: Double? {
        guard case .score(let value) = self else { return nil }
        return value
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let missingPolicy: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityCandidate
    let weights: [String: Double]
    let expected: ParityExpectation
}

private struct ParityCandidate: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
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
    let score: Score
}

private enum Score: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .value(value)
        } else {
            guard try container.decode(String.self) == "excluded" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected excluded score")
            }
            self = .excluded
        }
    }
}
