import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the golden vectors committed by `viamin/color_matching`.
///
/// The fixture is copied from `priv/parity/v1/corpus.json` in the backend at
/// the revision recorded in the README. Keep the selection assertion here as
/// well as the per-candidate score assertion: ties are part of the contract.
final class SolverParityCorpusTests: XCTestCase {
    func testCorpusMetadataDescribesTheSharedSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.tieBroke })
        XCTAssertTrue(corpus.scenarios.contains { $0.expected.selectedIndex == nil })
    }

    func testWeightedSquaredErrorScorerReplaysEveryParityScenario() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let palette = try scenario.palette
                .sorted { $0.index < $1.index }
                .map(makePaletteColor)
            let target = makeTarget(scenario.target)
            let weights = makeWeights(scenario.weights)
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            assertScores(actualScores, match: scenario.expected.scores, scenario: scenario.id)
            assertSelection(actualScores, palette: palette, match: scenario.expected, scenario: scenario.id)
        }
    }

    private func loadCorpus() throws -> SolverParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory.appendingPathComponent("Fixtures/solver-parity-v1.json")
        return try JSONDecoder().decode(SolverParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func makePaletteColor(_ vector: SolverParityVector) throws -> PaletteColor {
        let responses = vector.channels.reduce(into: [LightingCondition: IlluminationResponse]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = IlluminationResponse(brightness: entry.value)
        }
        let rgb = try XCTUnwrap(RGBColor(hex: vector.hexColor), "Invalid corpus color \(vector.hexColor)")
        return PaletteColor(id: vector.index ?? -1, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private func makeTarget(_ vector: SolverParityVector) -> TargetResponseVector {
        let values = vector.channels.reduce(into: [LightingCondition: Double]()) { result, entry in
            guard let condition = LightingCondition(rawValue: entry.key) else { return }
            result[condition] = entry.value
        }
        return TargetResponseVector(values)
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

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [SolverParityExpectedScore],
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(scenario): candidate count", file: file, line: line)
        for (actualScore, expectedScore) in zip(actual, expected.sorted { $0.index < $1.index }) {
            switch (actualScore, expectedScore.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actualValue), .value(let expectedValue)):
                XCTAssertEqual(actualValue, expectedValue, "\(scenario): score at \(expectedScore.index)", file: file, line: line)
            default:
                XCTFail("\(scenario): score at \(expectedScore.index) disagreed", file: file, line: line)
            }
        }
    }

    private func assertSelection(
        _ scores: [ScorerResult],
        palette: [PaletteColor],
        match expected: SolverParityExpected,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let ranked = scores.enumerated().compactMap { index, score -> (Int, Double)? in
            guard case .score(let value) = score else { return nil }
            return (index, value)
        }
        let lowestScore = ranked.map(\.1).min()
        let tiedIndices = ranked.compactMap { index, score in score == lowestScore ? index : nil }
        let selectedIndex = tiedIndices.first

        XCTAssertEqual(selectedIndex, expected.selectedIndex, "\(scenario): selected index", file: file, line: line)
        XCTAssertEqual(tiedIndices, expected.tiedIndices, "\(scenario): tied indices", file: file, line: line)
        XCTAssertEqual(expected.tieBroke, tiedIndices.count > 1, "\(scenario): tie evidence", file: file, line: line)

        guard let selectedIndex, let expectedError = expected.error else {
            XCTAssertNil(expected.selectedHexColor, "\(scenario): unmatched selection has no color", file: file, line: line)
            return
        }
        XCTAssertEqual(ranked.first { $0.0 == selectedIndex }?.1, expectedError, "\(scenario): selected error", file: file, line: line)
        XCTAssertEqual(palette[selectedIndex].hex, expected.selectedHexColor, "\(scenario): selected color", file: file, line: line)
    }
}

private struct SolverParityCorpus: Decodable {
    let algorithmVersion: Int
    let lightSources: [String]
    let missingPolicy: String
    let scenarios: [SolverParityScenario]
    let scorer: String
    let selection: String
}

private struct SolverParityScenario: Decodable {
    let expected: SolverParityExpected
    let id: String
    let palette: [SolverParityVector]
    let target: SolverParityVector
    let weights: [String: Double]
}

private struct SolverParityVector: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int?
}

private struct SolverParityExpected: Decodable {
    let error: Double?
    let scores: [SolverParityExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct SolverParityExpectedScore: Decodable {
    let index: Int
    let score: SolverParityScore
}

private enum SolverParityScore: Decodable {
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
