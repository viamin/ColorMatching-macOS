import Foundation
import XCTest
@testable import ColorComposerCore

/// Replays the golden vectors published by `viamin/color_matching`.
///
/// Keep this coupled to the server corpus rather than reproducing its cases
/// inline: it verifies scoring, exclusions, and earliest-index tie selection.
final class WeightedSquaredErrorParityTests: XCTestCase {
    func testCorpusMetadataDescribesTheMirroredSolverContract() throws {
        let corpus = try loadCorpus()

        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.scorer, "ColorMatching.WeightedSquaredError")
        XCTAssertEqual(corpus.selection, "earliest-index-wins")
        XCTAssertEqual(corpus.missingPolicy, "excluded-when-any-positive-weight-channel-missing")
        XCTAssertEqual(corpus.lightSources, ["white", "red", "green", "blue", "lps"])
    }

    func testCorpusIncludesTieAndExclusionCoverage() throws {
        let scenarios = try loadCorpus().scenarios

        XCTAssertTrue(scenarios.contains { $0.expected.tieBroke == true })
        XCTAssertTrue(scenarios.contains { $0.expected.selectedIndex == nil })
        XCTAssertTrue(scenarios.contains { $0.expected.scores.contains { $0.score == .excluded } })
    }

    func testWeightedSquaredErrorScorerMatchesEveryParityScenarioExactly() throws {
        let scorer = WeightedSquaredErrorScorer()

        for scenario in try loadCorpus().scenarios {
            let target = target(from: scenario.target)
            let weights = weights(from: scenario.weights)
            let palette = try scenario.palette.map(color(from:))
            let actualScores = palette.map { scorer.score(candidate: $0, target: target, weights: weights) }

            XCTAssertEqual(actualScores.count, scenario.expected.scores.count, scenario.id)
            for (index, pair) in zip(actualScores, scenario.expected.scores).enumerated() {
                let (actual, expected) = pair
                XCTAssertEqual(expected.index, index, scenario.id)
                assert(actual, matches: expected.score, scenarioID: scenario.id)
            }

            let selectedIndex = selectEarliestLowestScore(actualScores)
            XCTAssertEqual(selectedIndex, scenario.expected.selectedIndex, scenario.id)

            if let selectedIndex {
                let expectedHex = try XCTUnwrap(scenario.expected.selectedHexColor, scenario.id)
                let expectedError = try XCTUnwrap(scenario.expected.error, scenario.id)
                let expectedTieBroke = try XCTUnwrap(scenario.expected.tieBroke, scenario.id)
                XCTAssertEqual(palette[selectedIndex].hex, expectedHex, scenario.id)
                guard case .score(let error) = actualScores[selectedIndex] else {
                    return XCTFail("Selected candidate was excluded for \(scenario.id)")
                }
                XCTAssertEqual(error, expectedError, scenario.id)
                XCTAssertEqual(tiedIndices(in: actualScores, selectedIndex: selectedIndex).count > 1, expectedTieBroke, scenario.id)
            } else {
                XCTAssertNil(scenario.expected.error, scenario.id)
                XCTAssertNil(scenario.expected.selectedHexColor, scenario.id)
                XCTAssertNil(scenario.expected.tieBroke, scenario.id)
            }

            let tiedIndices = tiedIndices(in: actualScores, selectedIndex: selectedIndex)
            XCTAssertEqual(tiedIndices, scenario.expected.tiedIndices, scenario.id)
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = directory.appendingPathComponent("Fixtures/weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: url))
    }

    private func color(from vector: ParityVector) throws -> PaletteColor {
        guard let rgb = RGBColor(hex: vector.hexColor) else {
            throw ParityFixtureError.invalidHex(vector.hexColor)
        }
        let responses = vector.channels.compactMapValues { value in
            value.map { IlluminationResponse(brightness: $0) }
        }
        return PaletteColor(id: vector.index ?? 0, hex: vector.hexColor, rgb: rgb, responses: responses)
    }

    private func target(from vector: ParityVector) -> TargetResponseVector {
        TargetResponseVector(vector.channels.compactMapValues { $0 })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white"] ?? 0,
            red: values["red"] ?? 0,
            green: values["green"] ?? 0,
            blue: values["blue"] ?? 0,
            lps: values["lps"] ?? 0
        )
    }

    private func selectEarliestLowestScore(_ scores: [ScorerResult]) -> Int? {
        var selection: Int?
        var lowest = Double.infinity
        for (index, result) in scores.enumerated() {
            guard case .score(let score) = result, score < lowest else { continue }
            selection = index
            lowest = score
        }
        return selection
    }

    private func tiedIndices(in scores: [ScorerResult], selectedIndex: Int?) -> [Int] {
        guard let selectedIndex, case .score(let selectedScore) = scores[selectedIndex] else { return [] }
        return scores.enumerated().compactMap { index, result in
            guard case .score(let score) = result, score == selectedScore else { return nil }
            return index
        }
    }

    private func assert(
        _ actual: ScorerResult,
        matches expected: ParityScore,
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.excluded, .excluded):
            break
        case (.score(let actual), .score(let expected)):
            XCTAssertEqual(actual, expected, scenarioID, file: file, line: line)
        default:
            XCTFail("\(scenarioID): expected \(expected), got \(actual)", file: file, line: line)
        }
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
    let palette: [ParityVector]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityVector: Decodable {
    let channels: [String: Double?]
    let hexColor: String
    let index: Int?
}

private struct ParityExpected: Decodable {
    let error: Double?
    let scores: [ParityScoreRecord]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ParityScoreRecord: Decodable, Equatable {
    let index: Int
    let score: ParityScore
}

private enum ParityScore: Decodable, Equatable, CustomStringConvertible {
    case excluded
    case score(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let score = try? container.decode(Double.self) {
            self = .score(score)
        } else if try container.decode(String.self) == "excluded" {
            self = .excluded
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown parity score")
        }
    }

    var description: String {
        switch self {
        case .excluded: return "excluded"
        case .score(let value): return String(value)
        }
    }
}

private enum ParityFixtureError: Error {
    case invalidHex(String)
}
