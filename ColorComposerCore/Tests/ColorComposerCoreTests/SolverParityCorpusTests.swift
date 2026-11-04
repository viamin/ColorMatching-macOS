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
            try assertScoresMatch(scenario)
            try assertSelectionMatches(scenario)
        }
    }

    private func assertScoresMatch(_ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(responses(from: scenario.target.channels))
        let weights = weights(from: scenario.weights)

        for (candidate, expected) in zip(scenario.palette, scenario.expected.scores) {
            XCTAssertEqual(candidate.index, expected.index, "\(scenario.id) has an invalid score index", file: file, line: line)
            XCTAssertEqual(
                scorer.score(candidate: paletteColor(from: candidate), target: target, weights: weights),
                expected.scorerResult,
                "\(scenario.id) score mismatch for candidate \(candidate.index)",
                file: file,
                line: line
            )
        }
    }

    private func assertSelectionMatches(_ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = scenario.expected
        let selected = try solverSelection(for: scenario)

        XCTAssertEqual(selected.index, expected.selectedIndex, "\(scenario.id) selected index", file: file, line: line)
        XCTAssertEqual(selected.hex, expected.selectedHexColor, "\(scenario.id) selected color", file: file, line: line)
        if let expectedError = expected.error {
            guard let selectedError = selected.error else {
                return XCTFail("\(scenario.id) selected error was nil", file: file, line: line)
            }
            XCTAssertEqual(selectedError, expectedError, "\(scenario.id) selected error", file: file, line: line)
        } else {
            XCTAssertNil(selected.error, "\(scenario.id) selected error", file: file, line: line)
        }
        XCTAssertEqual(selected.tiedIndices, expected.tiedIndices, "\(scenario.id) tied indices", file: file, line: line)
        if let tieBroke = expected.tieBroke {
            XCTAssertEqual(selected.tiedIndices.count > 1, tieBroke, "\(scenario.id) tie evidence", file: file, line: line)
        } else {
            XCTAssertNil(selected.index, "\(scenario.id) has no selection", file: file, line: line)
        }
    }

    private func solverSelection(for scenario: Scenario) throws -> (index: Int?, hex: String?, error: Double?, tiedIndices: [Int]) {
        let weights = weights(from: scenario.weights)
        let targetResponses = responses(from: scenario.target.channels)
        let scorer = WeightedSquaredErrorScorer()
        let target = TargetResponseVector(targetResponses)
        let candidates = scenario.palette.map(paletteColor(from:))
        let scores = candidates.map { scorer.score(candidate: $0, target: target, weights: weights) }
        let scoreValues = scores.compactMap { result -> Double? in
            guard case .score(let value) = result else { return nil }
            return value
        }
        let bestScore = scoreValues.min()
        let tiedIndices = scores.enumerated().compactMap { index, result -> Int? in
            guard case .score(let score) = result, score == bestScore else { return nil }
            return index
        }

        guard let expectedIndex = scenario.expected.selectedIndex else {
            return (nil, nil, nil, tiedIndices)
        }

        let grids = Dictionary(uniqueKeysWithValues: weights.activeConditions.map { condition in
            (condition, BrightnessGrid(width: 1, height: 1, fill: targetResponses[condition]!))
        })
        let result = try CompositionSolver().solve(palette: candidates, sourceGrids: grids, weights: weights)
        let selectedIndex = result.colorIndex(x: 0, y: 0)
        XCTAssertEqual(selectedIndex, expectedIndex, "\(scenario.id) solver selection")
        return (selectedIndex, selectedIndex.map { scenario.palette[$0].hexColor }, result.error(x: 0, y: 0), tiedIndices)
    }

    private func loadCorpus() throws -> Corpus {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/parity-corpus-v1.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: fixture))
    }

    private func paletteColor(from entry: Entry) -> PaletteColor {
        PaletteColor(
            id: entry.index ?? -1,
            hex: entry.hexColor,
            rgb: RGBColor(hex: entry.hexColor)!,
            responses: responses(from: entry.channels).mapValues(IlluminationResponse.init(brightness:))
        )
    }

    private func responses(from channels: [String: Double]) -> [LightingCondition: Double] {
        Dictionary(uniqueKeysWithValues: channels.compactMap { key, value in
            LightingCondition(rawValue: key).map { ($0, value) }
        })
    }

    private func weights(from values: [String: Double]) -> ChannelWeights {
        ChannelWeights(
            white: values["white", default: 0],
            red: values["red", default: 0],
            green: values["green", default: 0],
            blue: values["blue", default: 0],
            lps: values["lps", default: 0]
        )
    }
}

private struct Corpus: Decodable {
    let algorithmVersion: Int
    let selection: String
    let missingPolicy: String
    let scenarios: [Scenario]
}

private struct Scenario: Decodable {
    let id: String
    let weights: [String: Double]
    let target: Entry
    let palette: [Entry]
    let expected: Expected
}

private struct Entry: Decodable {
    let index: Int?
    let hexColor: String
    let channels: [String: Double]
}

private struct Expected: Decodable {
    let error: Double?
    let scores: [ExpectedScore]
    let selectedHexColor: String?
    let selectedIndex: Int?
    let tieBroke: Bool?
    let tiedIndices: [Int]
}

private struct ExpectedScore: Decodable {
    let index: Int
    let score: Score

    var scorerResult: ScorerResult {
        switch score {
        case .value(let value): return .score(value)
        case .excluded: return .excluded
        }
    }
}

private enum Score: Decodable {
    case value(Double)
    case excluded

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
