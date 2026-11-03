import Foundation
import XCTest
@testable import ColorComposerCore

final class SolverParityCorpusTests: XCTestCase {
    func testCommittedCorpusDeclaresTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, LightingCondition.all.map(\.rawValue))
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorReplaysEveryCorpusScenarioExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let target = makeTarget(scenario.target)
            let weights = makeWeights(scenario.weights)
            let candidates = try scenario.palette
                .sorted { ($0.index ?? .max) < ($1.index ?? .max) }
                .map(makeColor)
            let results = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(results, equal: scenario.expected.scores, scenario: scenario.id)
            assertSelection(
                results,
                candidates: candidates,
                equal: scenario.expected,
                scenario: scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity-v1-corpus.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func makeTarget(_ vector: CorpusVector) -> TargetResponseVector {
        TargetResponseVector(vector.channels.compactMapValues { $0 })
    }

    private func makeColor(_ vector: CorpusVector) throws -> PaletteColor {
        let responses = vector.channels.compactMapValues { brightness in
            brightness.map(IlluminationResponse.init(brightness:))
        }
        return PaletteColor(
            id: vector.index ?? -1,
            hex: vector.hexColor,
            rgb: try XCTUnwrap(RGBColor(hex: vector.hexColor)),
            responses: responses
        )
    }

    private func makeWeights(_ weights: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: weights[LightingCondition.white.rawValue] ?? 0,
            red: weights[LightingCondition.red.rawValue] ?? 0,
            green: weights[LightingCondition.green.rawValue] ?? 0,
            blue: weights[LightingCondition.blue.rawValue] ?? 0,
            lps: weights[LightingCondition.lps.rawValue] ?? 0
        )
    }

    private func assertScores(
        _ results: [ScorerResult],
        equal expected: [ExpectedScore],
        scenario: String
    ) {
        XCTAssertEqual(results.count, expected.count, scenario)

        for (result, expectation) in zip(results, expected.sorted { $0.index < $1.index }) {
            switch (result, expectation.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actual), .value(let expected)):
                XCTAssertEqual(actual, expected, accuracy: 0, scenario)
            default:
                XCTFail("\(scenario): score did not match corpus expectation")
            }
        }
    }

    private func assertSelection(
        _ results: [ScorerResult],
        candidates: [PaletteColor],
        equal expected: ExpectedResult,
        scenario: String
    ) {
        let scored = results.enumerated().compactMap { index, result -> (Int, Double)? in
            guard case .score(let score) = result else { return nil }
            return (index, score)
        }
        let minimum = scored.map(\.1).min()
        let tiedIndices = minimum.map { value in
            scored.compactMap { $0.1 == value ? $0.0 : nil }
        } ?? []

        XCTAssertEqual(tiedIndices, expected.tiedIndices, scenario)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, scenario)

        guard let selectedIndex = expected.selectedIndex else {
            XCTAssertNil(minimum, scenario)
            XCTAssertNil(expected.error, scenario)
            XCTAssertNil(expected.tieBroke, scenario)
            XCTAssertNil(expected.selectedHexColor, scenario)
            return
        }

        guard let error = minimum else {
            return XCTFail("\(scenario): expected a selected candidate")
        }
        guard let expectedError = expected.error, let expectedHexColor = expected.selectedHexColor else {
            return XCTFail("\(scenario): corpus selection is incomplete")
        }
        XCTAssertEqual(error, expectedError, scenario)
        XCTAssertEqual(tiedIndices.first, selectedIndex, scenario)
        XCTAssertEqual(candidates[selectedIndex].hex, expectedHexColor, scenario)
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scorer: String
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [CorpusVector]
    let target: CorpusVector
    let weights: [String: Double]
    let expected: ExpectedResult
}

private struct CorpusVector: Decodable {
    let channels: [LightingCondition: Double?]
    let hexColor: String
    let index: Int?
}

private struct ExpectedResult: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: CorpusScore
}

private enum CorpusScore: Decodable {
    case excluded
    case value(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let marker = try? container.decode(String.self), marker == "excluded" {
            self = .excluded
        } else {
            self = .value(try container.decode(Double.self))
        }
    }
}

