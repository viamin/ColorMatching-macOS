import Foundation
import XCTest
@testable import ColorComposerCore

final class WeightedSquaredErrorParityTests: XCTestCase {
    func testV1CorpusMatchesScoresSelectionsAndTieEvidence() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.algorithmVersion, 1)
        XCTAssertEqual(corpus.selection, "earliest-index-wins")

        let scorer = WeightedSquaredErrorScorer()
        for scenario in corpus.scenarios {
            let target = TargetResponseVector(responses(from: scenario.target.channels))
            let weights = weights(from: scenario.weights)
            let results = scenario.palette.map { candidate in
                scorer.score(
                    candidate: color(from: candidate),
                    target: target,
                    weights: weights
                )
            }

            assertScores(
                results,
                match: scenario.expected.scores,
                scenarioID: scenario.id
            )
            assertSelection(
                results,
                match: scenario.expected,
                palette: scenario.palette,
                scenarioID: scenario.id
            )
        }
    }

    private func loadCorpus() throws -> ParityCorpus {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixture = testDirectory
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("weighted-squared-error-v1.json")
        return try JSONDecoder().decode(ParityCorpus.self, from: Data(contentsOf: fixture))
    }

    private func color(from candidate: ParityCandidate) -> PaletteColor {
        PaletteColor(
            id: candidate.index,
            hex: candidate.hexColor,
            rgb: RGBColor(hex: candidate.hexColor)!,
            responses: responses(from: candidate.channels).mapValues {
                IlluminationResponse(brightness: $0)
            }
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(
            uniqueKeysWithValues: channels.compactMap { name, brightness in
                LightingCondition(rawValue: name).map { ($0, brightness) }
            }
        )
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

    private func assertScores(
        _ actual: [ScorerResult],
        match expected: [ParityScore],
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "scenario: \(scenarioID)", file: file, line: line)
        for score in expected {
            guard actual.indices.contains(score.index) else {
                return XCTFail("Missing candidate \(score.index), scenario: \(scenarioID)", file: file, line: line)
            }

            switch (actual[score.index], score.score) {
            case (.excluded, .excluded):
                break
            case (.score(let actualScore), .value(let expectedScore)):
                XCTAssertEqual(actualScore, expectedScore, "scenario: \(scenarioID), candidate: \(score.index)", file: file, line: line)
            default:
                XCTFail("Unexpected score for scenario \(scenarioID), candidate: \(score.index)", file: file, line: line)
            }
        }
    }

    private func assertSelection(
        _ results: [ScorerResult],
        match expected: ParityExpected,
        palette: [ParityCandidate],
        scenarioID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var selectedIndex: Int?
        var selectedScore: Double?
        for (index, result) in results.enumerated() {
            guard case .score(let score) = result else { continue }
            if selectedScore == nil || score < selectedScore! {
                selectedIndex = index
                selectedScore = score
            }
        }

        XCTAssertEqual(selectedIndex, expected.selectedIndex, "scenario: \(scenarioID)", file: file, line: line)
        XCTAssertEqual(selectedScore, expected.error, "scenario: \(scenarioID)", file: file, line: line)
        XCTAssertEqual(
            selectedIndex.map { palette[$0].hexColor },
            expected.selectedHexColor,
            "scenario: \(scenarioID)",
            file: file,
            line: line
        )

        let tiedIndices = results.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == selectedScore else { return nil }
            return index
        }
        XCTAssertEqual(tiedIndices, expected.tiedIndices, "scenario: \(scenarioID)", file: file, line: line)
        if selectedIndex == nil {
            XCTAssertNil(expected.tieBroke, "scenario: \(scenarioID)", file: file, line: line)
        } else {
            XCTAssertEqual(
                tiedIndices.count > 1,
                expected.tieBroke ?? false,
                "scenario: \(scenarioID)",
                file: file,
                line: line
            )
        }
    }
}

private struct ParityCorpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let scenarios: [ParityScenario]
}

private struct ParityScenario: Decodable {
    let id: String
    let palette: [ParityCandidate]
    let target: ParityVector
    let weights: [String: Double]
    let expected: ParityExpected
}

private struct ParityCandidate: Decodable {
    let channels: [String: Double]
    let hexColor: String
    let index: Int
}

private struct ParityVector: Decodable {
    let channels: [String: Double]
}

private struct ParityExpected: Decodable {
    let error: Double?
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
    let scores: [ParityScore]
}

private struct ParityScore: Decodable {
    let index: Int
    let score: ParityExpectedScore
}

private enum ParityExpectedScore: Decodable {
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
